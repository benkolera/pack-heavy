import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

import type { AppSecrets } from "./secrets.ts";
import type { DatabaseResult } from "./database.ts";
import type { IdentityResult } from "./identity.ts";

interface Args {
    running: boolean;
    fqdn: string;
    imageTag: string;
    privateSubnetIds: pulumi.Output<string[]>;
    appSecurityGroupId: pulumi.Output<string>;
    repository: aws.ecr.Repository;
    appSecrets: AppSecrets;
    database: DatabaseResult;
    identity: IdentityResult;
}

export interface ComputeResult {
    cluster: aws.ecs.Cluster;
    serviceName: pulumi.Output<string | undefined>;
    attachToTargetGroup: (tgArn: pulumi.Output<string>) => void;
}

// ECS Fargate cluster + service. Single task pinned to the first private
// subnet so VPC endpoints (single-AZ) cover its traffic. ECS Exec is on
// for ad-hoc shell access (mix release scripts, seeding the user).
export function buildCompute(args: Args): ComputeResult {
    const cluster = new aws.ecs.Cluster("packheavy", {
        name: "packheavy",
        settings: [{ name: "containerInsights", value: "enabled" }],
    });

    if (!args.running) {
        return {
            cluster,
            serviceName: pulumi.output(undefined),
            attachToTargetGroup: () => {
                /* no-op when parked */
            },
        };
    }

    const region = aws.config.region!;

    const taskExecRole = new aws.iam.Role("packheavy-task-exec", {
        assumeRolePolicy: JSON.stringify({
            Version: "2012-10-17",
            Statement: [
                {
                    Effect: "Allow",
                    Principal: { Service: "ecs-tasks.amazonaws.com" },
                    Action: "sts:AssumeRole",
                },
            ],
        }),
        managedPolicyArns: ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"],
    });

    // Allow the execution role to read the SecretsManager secrets
    // referenced in the task definition's `secrets` block.
    new aws.iam.RolePolicy("packheavy-task-exec-secrets", {
        role: taskExecRole.id,
        policy: pulumi
            .all([
                args.appSecrets.secretKeyBase.arn,
                args.appSecrets.tokenSigningSecret.arn,
                args.database.masterUserSecretArn,
                args.identity.clientSecretArn,
            ])
            .apply(([skb, tss, master, cog]) =>
                JSON.stringify({
                    Version: "2012-10-17",
                    Statement: [
                        {
                            Effect: "Allow",
                            Action: ["secretsmanager:GetSecretValue"],
                            Resource: [skb, tss, master ?? "", cog ?? ""].filter(Boolean),
                        },
                    ],
                }),
            ),
    });

    const taskRole = new aws.iam.Role("packheavy-task", {
        assumeRolePolicy: JSON.stringify({
            Version: "2012-10-17",
            Statement: [
                {
                    Effect: "Allow",
                    Principal: { Service: "ecs-tasks.amazonaws.com" },
                    Action: "sts:AssumeRole",
                },
            ],
        }),
    });

    // ECS Exec — task role needs ssmmessages so `aws ecs execute-command`
    // can shell in.
    new aws.iam.RolePolicy("packheavy-task-exec-command", {
        role: taskRole.id,
        policy: JSON.stringify({
            Version: "2012-10-17",
            Statement: [
                {
                    Effect: "Allow",
                    Action: [
                        "ssmmessages:CreateControlChannel",
                        "ssmmessages:CreateDataChannel",
                        "ssmmessages:OpenControlChannel",
                        "ssmmessages:OpenDataChannel",
                    ],
                    Resource: "*",
                },
            ],
        }),
    });

    const logGroup = new aws.cloudwatch.LogGroup("packheavy", {
        name: "/ecs/packheavy",
        retentionInDays: 14,
    });

    const image = pulumi.interpolate`${args.repository.repositoryUrl}:${args.imageTag}`;

    const taskDef = new aws.ecs.TaskDefinition("packheavy", {
        family: "packheavy",
        cpu: "512",
        memory: "1024",
        networkMode: "awsvpc",
        requiresCompatibilities: ["FARGATE"],
        executionRoleArn: taskExecRole.arn,
        taskRoleArn: taskRole.arn,
        runtimePlatform: { cpuArchitecture: "ARM64", operatingSystemFamily: "LINUX" },
        containerDefinitions: pulumi
            .all([
                image,
                args.appSecrets.secretKeyBase.arn,
                args.appSecrets.tokenSigningSecret.arn,
                args.database.masterUserSecretArn,
                args.database.host,
                args.database.port.apply((p) => (p === undefined ? "" : String(p))),
                args.database.name,
                args.database.user,
                logGroup.name,
                args.identity.userPoolId,
                args.identity.clientId,
                args.identity.clientSecretArn,
                args.identity.domain,
                args.identity.issuer,
            ])
            .apply(([
                img, skbArn, tssArn, masterArn, dbHost, dbPort, dbName, dbUser, lg,
                cogPoolId, cogClientId, cogSecretArn, cogDomain, cogIssuer,
            ]) => {
                const baseEnv = [
                    { name: "PHX_SERVER", value: "true" },
                    { name: "PHX_HOST", value: args.fqdn },
                    { name: "PORT", value: "4000" },
                    { name: "POOL_SIZE", value: "10" },
                    { name: "DATABASE_HOST", value: dbHost ?? "" },
                    { name: "DATABASE_PORT", value: String(dbPort ?? 5432) },
                    { name: "DATABASE_NAME", value: dbName ?? "" },
                    { name: "DATABASE_USER", value: dbUser ?? "" },
                ];
                const cognitoEnv = cogPoolId
                    ? [
                          { name: "COGNITO_USER_POOL_ID", value: cogPoolId },
                          { name: "COGNITO_CLIENT_ID", value: cogClientId ?? "" },
                          { name: "COGNITO_DOMAIN", value: cogDomain ?? "" },
                          { name: "COGNITO_ISSUER", value: cogIssuer ?? "" },
                      ]
                    : [];

                const baseSecrets = [
                    { name: "SECRET_KEY_BASE", valueFrom: skbArn },
                    { name: "TOKEN_SIGNING_SECRET", valueFrom: tssArn },
                    // RDS-managed master secret is JSON; we only
                    // want the password key (user is already in env).
                    { name: "DATABASE_PASSWORD", valueFrom: `${masterArn}:password::` },
                ];
                const cognitoSecrets = cogSecretArn
                    ? [{ name: "COGNITO_CLIENT_SECRET", valueFrom: cogSecretArn }]
                    : [];

                return JSON.stringify([
                    {
                        name: "app",
                        image: img,
                        essential: true,
                        portMappings: [{ containerPort: 4000, protocol: "tcp" }],
                        environment: [...baseEnv, ...cognitoEnv],
                        secrets: [...baseSecrets, ...cognitoSecrets],
                        logConfiguration: {
                            logDriver: "awslogs",
                            options: {
                                "awslogs-group": lg,
                                "awslogs-region": region,
                                "awslogs-stream-prefix": "app",
                            },
                        },
                        healthCheck: {
                            command: [
                                "CMD-SHELL",
                                "wget -qO- http://localhost:4000/health | grep -q ok || exit 1",
                            ],
                            interval: 15,
                            timeout: 5,
                            retries: 3,
                            startPeriod: 30,
                        },
                    },
                ]);
            }),
    });

    const result: ComputeResult = {
        cluster,
        serviceName: pulumi.output(undefined),
        attachToTargetGroup: (targetGroupArn) => {
            const service = new aws.ecs.Service("packheavy", {
                name: "packheavy",
                cluster: cluster.arn,
                desiredCount: 1,
                launchType: "FARGATE",
                taskDefinition: taskDef.arn,
                enableExecuteCommand: true,
                networkConfiguration: {
                    subnets: args.privateSubnetIds.apply((ids) => [ids[0]]),
                    securityGroups: [args.appSecurityGroupId],
                    assignPublicIp: false,
                },
                loadBalancers: [
                    {
                        targetGroupArn,
                        containerName: "app",
                        containerPort: 4000,
                    },
                ],
                deploymentMinimumHealthyPercent: 0,
                deploymentMaximumPercent: 200,
                // Block `pulumi up` until ECS reports steady state
                // (running tasks == desired, no in-flight deploy).
                // Catches broken images at apply time instead of
                // letting the ALB silently 503 after Pulumi declares
                // success.
                waitForSteadyState: true,
            });
            (result as { serviceName: pulumi.Output<string | undefined> }).serviceName =
                service.name;
        },
    };

    return result;
}

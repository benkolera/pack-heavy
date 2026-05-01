import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";
import * as awsx from "@pulumi/awsx";

interface Args {
    running: boolean;
}

interface Result {
    vpcId: pulumi.Output<string>;
    publicSubnetIds: pulumi.Output<string[]>;
    privateSubnetIds: pulumi.Output<string[]>;
    albSecurityGroupId: pulumi.Output<string>;
    appSecurityGroupId: pulumi.Output<string>;
    dbSecurityGroupId: pulumi.Output<string>;
}

// Two AZs because RDS subnet groups require ≥2; ALB also wants 2. The
// Fargate task is pinned to the first private subnet so VPC interface
// endpoints only need to exist in that one AZ.
export function buildNetwork(args: Args): Result {
    const region = aws.config.region!;

    const vpc = new awsx.ec2.Vpc("packheavy", {
        numberOfAvailabilityZones: 2,
        natGateways: { strategy: awsx.ec2.NatGatewayStrategy.None },
        subnetSpecs: [
            { type: awsx.ec2.SubnetType.Public, cidrMask: 24 },
            { type: awsx.ec2.SubnetType.Private, cidrMask: 24 },
        ],
        enableDnsHostnames: true,
        enableDnsSupport: true,
    });

    const albSg = new aws.ec2.SecurityGroup("alb-sg", {
        vpcId: vpc.vpcId,
        description: "Allow inbound HTTP/HTTPS from the world",
        ingress: [
            { protocol: "tcp", fromPort: 80, toPort: 80, cidrBlocks: ["0.0.0.0/0"] },
            { protocol: "tcp", fromPort: 443, toPort: 443, cidrBlocks: ["0.0.0.0/0"] },
        ],
        egress: [{ protocol: "-1", fromPort: 0, toPort: 0, cidrBlocks: ["0.0.0.0/0"] }],
    });

    const appSg = new aws.ec2.SecurityGroup("app-sg", {
        vpcId: vpc.vpcId,
        description: "Allow inbound 4000 from ALB only",
        egress: [{ protocol: "-1", fromPort: 0, toPort: 0, cidrBlocks: ["0.0.0.0/0"] }],
    });

    new aws.ec2.SecurityGroupRule("app-sg-from-alb", {
        type: "ingress",
        securityGroupId: appSg.id,
        sourceSecurityGroupId: albSg.id,
        protocol: "tcp",
        fromPort: 4000,
        toPort: 4000,
    });

    const dbSg = new aws.ec2.SecurityGroup("db-sg", {
        vpcId: vpc.vpcId,
        description: "Allow Postgres from app only",
        egress: [{ protocol: "-1", fromPort: 0, toPort: 0, cidrBlocks: ["0.0.0.0/0"] }],
    });

    new aws.ec2.SecurityGroupRule("db-sg-from-app", {
        type: "ingress",
        securityGroupId: dbSg.id,
        sourceSecurityGroupId: appSg.id,
        protocol: "tcp",
        fromPort: 5432,
        toPort: 5432,
    });

    const vpceSg = new aws.ec2.SecurityGroup("vpce-sg", {
        vpcId: vpc.vpcId,
        description: "VPC interface endpoints - 443 from app",
        egress: [{ protocol: "-1", fromPort: 0, toPort: 0, cidrBlocks: ["0.0.0.0/0"] }],
    });

    new aws.ec2.SecurityGroupRule("vpce-sg-from-app", {
        type: "ingress",
        securityGroupId: vpceSg.id,
        sourceSecurityGroupId: appSg.id,
        protocol: "tcp",
        fromPort: 443,
        toPort: 443,
    });

    // Endpoints + NAT — only declared while running, since they bill hourly.
    if (args.running) {
        // Gateway endpoint for S3 (free) — Fargate ECR layer pulls go via this.
        new aws.ec2.VpcEndpoint("s3-gw", {
            vpcId: vpc.vpcId,
            serviceName: `com.amazonaws.${region}.s3`,
            vpcEndpointType: "Gateway",
            routeTableIds: vpc.privateSubnetIds.apply(async (ids) => {
                // Fetch route tables associated with each private subnet.
                const tables = await Promise.all(
                    ids.map((id) =>
                        aws.ec2.getRouteTable({ subnetId: id }, { async: true }).then((rt) => rt.id),
                    ),
                );
                return Array.from(new Set(tables));
            }),
        });

        // Pin interface endpoints to the first private subnet (single AZ to
        // halve cost; Fargate task is also pinned there).
        const firstPrivateSubnet = vpc.privateSubnetIds.apply((ids) => [ids[0]]);

        const interfaceServices = ["ecr.api", "ecr.dkr", "secretsmanager", "logs"];
        for (const svc of interfaceServices) {
            new aws.ec2.VpcEndpoint(`${svc}-if`, {
                vpcId: vpc.vpcId,
                serviceName: `com.amazonaws.${region}.${svc}`,
                vpcEndpointType: "Interface",
                privateDnsEnabled: true,
                subnetIds: firstPrivateSubnet,
                securityGroupIds: [vpceSg.id],
            });
        }

        // Single NAT in the first public subnet → 0.0.0.0/0 from the first
        // private subnet's route table. Needed for Cognito hosted UI
        // (`*.auth.<region>.amazoncognito.com`) which has no PrivateLink.
        // ~$32/mo while running, $0 when parked since the whole block is
        // running-gated.
        const eip = new aws.ec2.Eip("nat-eip", { domain: "vpc" });
        const nat = new aws.ec2.NatGateway("nat", {
            allocationId: eip.id,
            subnetId: vpc.publicSubnetIds.apply((ids) => ids[0]),
        });

        const firstPrivateRtId = vpc.privateSubnetIds.apply(async (ids) => {
            const rt = await aws.ec2.getRouteTable({ subnetId: ids[0] }, { async: true });
            return rt.id;
        });

        new aws.ec2.Route("nat-default", {
            routeTableId: firstPrivateRtId,
            destinationCidrBlock: "0.0.0.0/0",
            natGatewayId: nat.id,
        });
    }

    return {
        vpcId: vpc.vpcId,
        publicSubnetIds: vpc.publicSubnetIds,
        privateSubnetIds: vpc.privateSubnetIds,
        albSecurityGroupId: albSg.id,
        appSecurityGroupId: appSg.id,
        dbSecurityGroupId: dbSg.id,
    };
}

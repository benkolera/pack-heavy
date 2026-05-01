import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

interface Args {
    running: boolean;
    subnetIds: pulumi.Output<string[]>;
    dbSecurityGroupId: pulumi.Output<string>;
}

export interface DatabaseResult {
    endpoint: pulumi.Output<string | undefined>;
    // Pieces consumed by the ECS task definition. compute.ts wires
    // DATABASE_PASSWORD from masterUserSecretArn (via JSON key `password`).
    host: pulumi.Output<string | undefined>;
    port: pulumi.Output<number | undefined>;
    name: pulumi.Output<string | undefined>;
    user: pulumi.Output<string | undefined>;
    masterUserSecretArn: pulumi.Output<string | undefined>;
    // Composite for places that prefer a URL — left unused for prod.
    databaseUrl: pulumi.Output<string | undefined>;
}

// db.t4g.micro Postgres 16. RDS auto-rotates the master password into
// SecretsManager (manageMasterUserPassword). When running=false the
// instance is destroyed, leaving a final snapshot keyed off the stable
// final-snapshot-id so unparking restores the same data.
export function buildDatabase(args: Args): DatabaseResult {
    const subnetGroup = new aws.rds.SubnetGroup("packheavy", {
        subnetIds: args.subnetIds,
        description: "packheavy private subnets",
    });

    if (!args.running) {
        return {
            endpoint: pulumi.output(undefined),
            host: pulumi.output(undefined),
            port: pulumi.output(undefined),
            name: pulumi.output(undefined),
            user: pulumi.output(undefined),
            masterUserSecretArn: pulumi.output(undefined),
            databaseUrl: pulumi.output(undefined),
        };
    }

    const instance = new aws.rds.Instance(
        "packheavy",
        {
            identifier: "packheavy",
            engine: "postgres",
            engineVersion: "16.13",
            instanceClass: "db.t4g.micro",
            allocatedStorage: 20,
            storageType: "gp3",
            storageEncrypted: true,
            dbName: "packheavy",
            username: "packheavy",
            manageMasterUserPassword: true,
            publiclyAccessible: false,
            dbSubnetGroupName: subnetGroup.name,
            vpcSecurityGroupIds: [args.dbSecurityGroupId],
            backupRetentionPeriod: 7,
            deletionProtection: false,
            skipFinalSnapshot: false,
            finalSnapshotIdentifier: "packheavy-final",
            applyImmediately: true,
        },
        { protect: false },
    );

    const masterSecretArn = instance.masterUserSecrets.apply((s) => s?.[0]?.secretArn);

    const databaseUrl = pulumi
        .all([instance.address, instance.port, instance.username, instance.dbName])
        .apply(
            ([host, port, user, db]) =>
                `ecto://${user}:DATABASE_PASSWORD_PLACEHOLDER@${host}:${port}/${db}`,
        );

    return {
        endpoint: instance.endpoint,
        host: instance.address,
        port: instance.port,
        name: instance.dbName,
        user: instance.username,
        masterUserSecretArn: masterSecretArn,
        databaseUrl,
    };
}

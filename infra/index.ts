import * as pulumi from "@pulumi/pulumi";

import { buildNetwork } from "./src/network";
import { buildSecrets } from "./src/secrets";
import { buildDatabase } from "./src/database";
import { buildRegistry } from "./src/registry";
import { buildCompute } from "./src/compute";
import { buildEdge } from "./src/edge";
import { buildIdentity } from "./src/identity";

const cfg = new pulumi.Config("packheavy");

const config = {
    domain: cfg.require("domain"),
    subdomain: cfg.require("subdomain"),
    hostedZoneId: cfg.require("hostedZoneId"),
    imageTag: cfg.require("imageTag"),
    running: cfg.requireBoolean("running"),
    enableCognito: cfg.requireBoolean("enableCognito"),
};

const fqdn = `${config.subdomain}.${config.domain}`;

const network = buildNetwork({ running: config.running });

const registry = buildRegistry();

const secrets = buildSecrets();

const database = buildDatabase({
    running: config.running,
    subnetIds: network.privateSubnetIds,
    dbSecurityGroupId: network.dbSecurityGroupId,
});

const identity = buildIdentity({
    enabled: config.enableCognito,
    fqdn,
});

const compute = buildCompute({
    running: config.running,
    fqdn,
    imageTag: config.imageTag,
    privateSubnetIds: network.privateSubnetIds,
    appSecurityGroupId: network.appSecurityGroupId,
    repository: registry.repository,
    appSecrets: secrets,
    database,
});

const edge = buildEdge({
    running: config.running,
    fqdn,
    domain: config.domain,
    hostedZoneId: config.hostedZoneId,
    publicSubnetIds: network.publicSubnetIds,
    vpcId: network.vpcId,
    albSecurityGroupId: network.albSecurityGroupId,
});

// Wire compute → ALB target group after both exist. No-op when parked.
if (config.running) {
    compute.attachToTargetGroup(edge.targetGroupArn);
}

export const albDnsName = edge.albDnsName;
export const ecrRepositoryUrl = registry.repository.repositoryUrl;
export const databaseEndpoint = database.endpoint;
export const cognitoUserPoolId = identity.userPoolId;
export const url = pulumi.interpolate`https://${fqdn}`;

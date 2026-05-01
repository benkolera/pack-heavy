import * as pulumi from "@pulumi/pulumi";

import { buildNetwork } from "./src/network.ts";
import { buildSecrets } from "./src/secrets.ts";
import { buildDatabase } from "./src/database.ts";
import { buildRegistry } from "./src/registry.ts";
import { buildCompute } from "./src/compute.ts";
import { buildEdge } from "./src/edge.ts";
import { buildIdentity } from "./src/identity.ts";

const cfg = new pulumi.Config("packheavy");

const config = {
    domain: cfg.require("domain"),
    subdomain: cfg.require("subdomain"),
    hostedZoneId: cfg.require("hostedZoneId"),
    imageTag: cfg.require("imageTag"),
    running: cfg.requireBoolean("running"),
    enableCognito: cfg.requireBoolean("enableCognito"),
    // Required only when enableCognito is true; identity.ts validates.
    adminEmail: cfg.getSecret("adminEmail"),
    googleClientId: cfg.getSecret("googleClientId"),
    googleClientSecret: cfg.getSecret("googleClientSecret"),
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
    adminEmail: config.adminEmail,
    googleClientId: config.googleClientId,
    googleClientSecret: config.googleClientSecret,
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
    identity,
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
export const cognitoClientId = identity.clientId;
export const cognitoDomain = identity.domain;
export const cognitoIssuer = identity.issuer;
// Convenience: paste this URL into your Google OAuth client's
// "Authorised redirect URIs" after `pulumi up` provisions Cognito.
export const cognitoGoogleRedirectUri = identity.domain.apply((d) =>
    d ? `${d}/oauth2/idpresponse` : undefined,
);
export const url = pulumi.interpolate`https://${fqdn}`;

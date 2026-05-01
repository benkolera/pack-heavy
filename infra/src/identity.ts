import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

interface Args {
    enabled: boolean;
    fqdn: string;
    adminEmail?: pulumi.Output<string>;
    googleClientId?: pulumi.Output<string>;
    googleClientSecret?: pulumi.Output<string>;
}

export interface IdentityResult {
    userPoolId: pulumi.Output<string | undefined>;
    clientId: pulumi.Output<string | undefined>;
    clientSecretArn: pulumi.Output<string | undefined>;
    domain: pulumi.Output<string | undefined>;
    issuer: pulumi.Output<string | undefined>;
}

const undef = pulumi.output<string | undefined>(undefined);

const disabled: IdentityResult = {
    userPoolId: undef,
    clientId: undef,
    clientSecretArn: undef,
    domain: undef,
    issuer: undef,
};

// Cognito user pool federated to Google, with hosted UI enabled. The
// ECS task does the OAuth code-exchange server-side against
// `<domain>.auth.<region>.amazoncognito.com/oauth2/token`, so the task
// needs internet egress (NAT gateway in network.ts).
//
// Defence-in-depth allowlist: a pre-sign-up Lambda blocks every email
// that isn't `adminEmail`. Even if the Google OAuth client were
// misconfigured to allow any Google account, no Cognito user would be
// created for them.
export function buildIdentity(args: Args): IdentityResult {
    if (!args.enabled) {
        return disabled;
    }

    if (!args.adminEmail || !args.googleClientId || !args.googleClientSecret) {
        throw new Error(
            "identity.ts: enableCognito=true requires packheavy:adminEmail, " +
            "packheavy:googleClientId (secret), packheavy:googleClientSecret (secret).",
        );
    }

    const region = aws.config.region!;
    const accountId = aws.getCallerIdentity({}).then((c) => c.accountId);

    // -- Pre-sign-up Lambda: email allowlist ---------------------------------

    const lambdaRole = new aws.iam.Role("cognito-presignup-role", {
        assumeRolePolicy: JSON.stringify({
            Version: "2012-10-17",
            Statement: [
                {
                    Effect: "Allow",
                    Principal: { Service: "lambda.amazonaws.com" },
                    Action: "sts:AssumeRole",
                },
            ],
        }),
        managedPolicyArns: [
            "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
        ],
    });

    // Inline ESM Node.js. Auto-confirms the allowlisted email and
    // auto-links its Google identity so the user lands signed-in
    // without a Cognito-side confirmation step.
    const presignupCode = pulumi.interpolate`
exports.handler = async (event) => {
  const allow = ${args.adminEmail.apply((e) => JSON.stringify(e))};
  const email = (event.request && event.request.userAttributes && event.request.userAttributes.email || "").toLowerCase();
  if (email !== allow.toLowerCase()) {
    throw new Error("Email not on allowlist: " + email);
  }
  event.response.autoConfirmUser = true;
  event.response.autoVerifyEmail = true;
  return event;
};
`.apply((s) => s);

    const presignupZip = presignupCode.apply(
        (code) =>
            new pulumi.asset.AssetArchive({
                "index.js": new pulumi.asset.StringAsset(code),
            }),
    );

    const presignupFn = new aws.lambda.Function("cognito-presignup", {
        runtime: "nodejs20.x",
        handler: "index.handler",
        role: lambdaRole.arn,
        code: presignupZip,
        timeout: 5,
    });

    new aws.lambda.Permission("cognito-presignup-invoke", {
        action: "lambda:InvokeFunction",
        function: presignupFn.name,
        principal: "cognito-idp.amazonaws.com",
        sourceArn: pulumi.interpolate`arn:aws:cognito-idp:${region}:${accountId}:userpool/*`,
    });

    // -- User pool ------------------------------------------------------------

    const userPool = new aws.cognito.UserPool("packheavy", {
        name: "packheavy",
        usernameAttributes: ["email"],
        autoVerifiedAttributes: ["email"],
        adminCreateUserConfig: {
            allowAdminCreateUserOnly: true,
        },
        passwordPolicy: {
            minimumLength: 12,
            requireLowercase: true,
            requireUppercase: true,
            requireNumbers: true,
            requireSymbols: true,
            temporaryPasswordValidityDays: 1,
        },
        // Schema must declare email as required+mutable so the
        // pre-sign-up Lambda can read it from request.userAttributes.
        schemas: [
            {
                name: "email",
                attributeDataType: "String",
                required: true,
                mutable: true,
                stringAttributeConstraints: { minLength: "5", maxLength: "256" },
            },
        ],
        lambdaConfig: {
            preSignUp: presignupFn.arn,
        },
        accountRecoverySetting: {
            recoveryMechanisms: [{ name: "verified_email", priority: 1 }],
        },
        deletionProtection: "ACTIVE",
    });

    // -- Hosted-UI domain -----------------------------------------------------
    // Globally unique within the region. Suffix with last 8 chars of
    // account ID — short, stable, and avoids `packheavy-auth` clashing
    // with a different account using the same name.
    const domainPrefix = pulumi.output(accountId).apply(
        (id) => `packheavy-auth-${id.slice(-8)}`,
    );

    const userPoolDomain = new aws.cognito.UserPoolDomain("packheavy-auth", {
        domain: domainPrefix,
        userPoolId: userPool.id,
    });

    // -- Google IDP -----------------------------------------------------------

    const googleIdp = new aws.cognito.IdentityProvider("google", {
        userPoolId: userPool.id,
        providerName: "Google",
        providerType: "Google",
        providerDetails: {
            authorize_scopes: "openid email profile",
            client_id: args.googleClientId,
            client_secret: args.googleClientSecret,
        },
        attributeMapping: {
            email: "email",
            username: "sub",
        },
    });

    // -- App client -----------------------------------------------------------

    const userPoolClient = new aws.cognito.UserPoolClient(
        "packheavy",
        {
            userPoolId: userPool.id,
            generateSecret: true,
            allowedOauthFlowsUserPoolClient: true,
            allowedOauthFlows: ["code"],
            allowedOauthScopes: ["openid", "email", "profile"],
            callbackUrls: [`https://${args.fqdn}/auth/user/cognito/callback`],
            logoutUrls: [`https://${args.fqdn}/`],
            supportedIdentityProviders: ["Google"],
            preventUserExistenceErrors: "ENABLED",
            // Cognito-side; AshAuth holds its own session.
            accessTokenValidity: 60,
            idTokenValidity: 60,
            refreshTokenValidity: 30,
            tokenValidityUnits: {
                accessToken: "minutes",
                idToken: "minutes",
                refreshToken: "days",
            },
            explicitAuthFlows: ["ALLOW_REFRESH_TOKEN_AUTH"],
        },
        // Client must be created after the IDP is registered or
        // `supportedIdentityProviders: ["Google"]` is rejected.
        { dependsOn: [googleIdp] },
    );

    // -- Wrap client secret in Secrets Manager so the ECS task can pull it
    //    via the existing VPC interface endpoint, matching the pattern used
    //    for SECRET_KEY_BASE / TOKEN_SIGNING_SECRET / DB master password.

    const clientSecretSecret = new aws.secretsmanager.Secret("cognito-client-secret", {
        name: "packheavy/cognito-client-secret",
        description: "Cognito app client secret",
        recoveryWindowInDays: 0,
    });

    new aws.secretsmanager.SecretVersion("cognito-client-secret-v", {
        secretId: clientSecretSecret.id,
        secretString: userPoolClient.clientSecret,
    });

    const issuer = pulumi.interpolate`https://cognito-idp.${region}.amazonaws.com/${userPool.id}`;
    const domainUrl = pulumi.interpolate`https://${userPoolDomain.domain}.auth.${region}.amazoncognito.com`;

    return {
        userPoolId: userPool.id.apply((v): string | undefined => v),
        clientId: userPoolClient.id.apply((v): string | undefined => v),
        clientSecretArn: clientSecretSecret.arn.apply((v): string | undefined => v),
        domain: domainUrl.apply((v): string | undefined => v),
        issuer: issuer.apply((v): string | undefined => v),
    };
}

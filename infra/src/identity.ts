import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";
import * as auth0 from "@pulumi/auth0";

interface Args {
    enabled: boolean;
    fqdn: string;
    // Comma-separated allowlist of email addresses permitted to log in.
    // Whitespace around each entry is trimmed; case is ignored at match
    // time.
    allowedEmails?: pulumi.Output<string>;
    googleClientId?: pulumi.Output<string>;
    googleClientSecret?: pulumi.Output<string>;
    auth0Domain?: pulumi.Output<string>;
    auth0MgmtClientId?: pulumi.Output<string>;
    auth0MgmtClientSecret?: pulumi.Output<string>;
}

export interface IdentityResult {
    clientId: pulumi.Output<string | undefined>;
    clientSecretArn: pulumi.Output<string | undefined>;
    domain: pulumi.Output<string | undefined>;
    issuer: pulumi.Output<string | undefined>;
    googleRedirectUri: pulumi.Output<string | undefined>;
}

const undef = pulumi.output<string | undefined>(undefined);

const disabled: IdentityResult = {
    clientId: undef,
    clientSecretArn: undef,
    domain: undef,
    issuer: undef,
    googleRedirectUri: undef,
};

// Auth0 tenant configured for Universal Login with Google as the only
// connection. A post-login Action denies any login whose email isn't
// in the `allowedEmails` allowlist.
//
// You provision the tenant + a Management API M2M client manually
// (Auth0 doesn't expose tenant creation via API). Required scopes on
// the M2M client: read/create/update/delete on clients, connections,
// actions, and triggers.
export function buildIdentity(args: Args): IdentityResult {
    if (!args.enabled) {
        return disabled;
    }

    if (
        !args.allowedEmails ||
        !args.googleClientId ||
        !args.googleClientSecret ||
        !args.auth0Domain ||
        !args.auth0MgmtClientId ||
        !args.auth0MgmtClientSecret
    ) {
        throw new Error(
            "identity.ts: enableAuth0=true requires packheavy:allowedEmails, " +
            "packheavy:googleClientId, packheavy:googleClientSecret, " +
            "packheavy:auth0Domain, packheavy:auth0MgmtClientId, " +
            "packheavy:auth0MgmtClientSecret.",
        );
    }

    const tenant = new auth0.Provider("auth0-tenant", {
        domain: args.auth0Domain,
        clientId: args.auth0MgmtClientId,
        clientSecret: args.auth0MgmtClientSecret,
    });

    const tenantOpts = { provider: tenant } as const;

    // -- Application (regular web app) ---------------------------------------

    const app = new auth0.Client(
        "packheavy",
        {
            name: "packheavy",
            appType: "regular_web",
            oidcConformant: true,
            grantTypes: ["authorization_code", "refresh_token"],
            callbacks: [`https://${args.fqdn}/auth/user/auth0/callback`],
            allowedLogoutUrls: [`https://${args.fqdn}/`],
        },
        tenantOpts,
    );

    // Separate resource for the client secret in v1+ of the underlying
    // terraform-provider-auth0. `clientSecretPost` is the auth method
    // AshAuthentication's oauth2 strategy uses by default.
    const appCreds = new auth0.ClientCredentials(
        "packheavy-credentials",
        {
            clientId: app.clientId,
            authenticationMethod: "client_secret_post",
        },
        tenantOpts,
    );

    // -- Google connection ---------------------------------------------------

    const googleConn = new auth0.Connection(
        "google",
        {
            name: "google-oauth2",
            strategy: "google-oauth2",
            options: {
                clientId: args.googleClientId,
                clientSecret: args.googleClientSecret,
                scopes: ["email", "profile"],
            },
        },
        tenantOpts,
    );

    new auth0.ConnectionClients(
        "google-clients",
        {
            connectionId: googleConn.id,
            enabledClients: [app.clientId],
        },
        tenantOpts,
    );

    // -- Post-login allowlist Action -----------------------------------------

    const allowlistCode = args.allowedEmails.apply((csv) => {
        const list = csv
            .split(",")
            .map((e) => e.trim().toLowerCase())
            .filter((e) => e.length > 0);
        return `exports.onExecutePostLogin = async (event, api) => {
  const allow = ${JSON.stringify(list)};
  const userEmail = (event.user && event.user.email || "").toLowerCase();
  if (!allow.includes(userEmail)) {
    api.access.deny("Email not on allowlist: " + userEmail);
  }
};
`;
    });

    const allowlistAction = new auth0.Action(
        "email-allowlist",
        {
            name: "packheavy-email-allowlist",
            code: allowlistCode,
            deploy: true,
            supportedTriggers: { id: "post-login", version: "v3" },
        },
        tenantOpts,
    );

    new auth0.TriggerActions(
        "post-login-actions",
        {
            trigger: "post-login",
            actions: [{ id: allowlistAction.id, displayName: allowlistAction.name }],
        },
        { ...tenantOpts, dependsOn: [allowlistAction] },
    );

    // -- Wrap client secret in Secrets Manager so the ECS task can pull it
    //    via the existing VPC interface endpoint, matching the pattern used
    //    for SECRET_KEY_BASE / TOKEN_SIGNING_SECRET / DB master password.

    const clientSecretSecret = new aws.secretsmanager.Secret("auth0-client-secret", {
        name: "packheavy/auth0-client-secret",
        description: "Auth0 application client secret",
        recoveryWindowInDays: 0,
    });

    new aws.secretsmanager.SecretVersion("auth0-client-secret-v", {
        secretId: clientSecretSecret.id,
        secretString: appCreds.clientSecret,
    });

    const issuer = pulumi.interpolate`https://${args.auth0Domain}/`;
    const domainUrl = pulumi.interpolate`https://${args.auth0Domain}`;
    // Paste this URL into your Google OAuth client's "Authorised redirect
    // URIs" so Auth0 can finish the OIDC handshake with Google.
    const googleRedirect = pulumi.interpolate`https://${args.auth0Domain}/login/callback`;

    return {
        clientId: app.clientId.apply((v): string | undefined => v),
        clientSecretArn: clientSecretSecret.arn.apply((v): string | undefined => v),
        domain: domainUrl.apply((v): string | undefined => v),
        issuer: issuer.apply((v): string | undefined => v),
        googleRedirectUri: googleRedirect.apply((v): string | undefined => v),
    };
}

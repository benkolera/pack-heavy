import * as pulumi from "@pulumi/pulumi";

interface Args {
    enabled: boolean;
    fqdn: string;
}

export interface IdentityResult {
    userPoolId: pulumi.Output<string | undefined>;
    clientId: pulumi.Output<string | undefined>;
    domain: pulumi.Output<string | undefined>;
}

// Cognito user pool + Google IdP + app client. Deferred until the app
// has a way to reach Cognito's hosted UI back-channel
// (`<domain>.auth.<region>.amazoncognito.com/oauth2/token`), which needs
// either NAT or a public-subnet task placement. While
// `packheavy:enableCognito = false` we declare nothing.
export function buildIdentity(args: Args): IdentityResult {
    if (!args.enabled) {
        return {
            userPoolId: pulumi.output(undefined),
            clientId: pulumi.output(undefined),
            domain: pulumi.output(undefined),
        };
    }

    // Implementation deferred until SSO is wired. When you flip the flag,
    // populate this with:
    //   - aws.cognito.UserPool (allowAdminCreateUserOnly: true,
    //     usernameAttributes: ["email"])
    //   - aws.cognito.IdentityProvider (Google, clientId/secret from
    //     pulumi config secrets)
    //   - aws.cognito.UserPoolDomain (`packheavy-auth`)
    //   - aws.cognito.UserPoolClient (callback URL =
    //     `https://${args.fqdn}/auth/cognito/callback`,
    //     supportedIdentityProviders: ["Google"])
    // and update lib/packheavy/accounts/user.ex strategies to add
    // an `oauth2 :cognito` strategy reading env vars supplied by
    // compute.ts.
    throw new Error("identity.ts: enableCognito is true but not implemented yet");
}

import * as aws from "@pulumi/aws";
import * as random from "@pulumi/random";

export interface AppSecrets {
    secretKeyBase: aws.secretsmanager.Secret;
    tokenSigningSecret: aws.secretsmanager.Secret;
}

// SECRET_KEY_BASE and TOKEN_SIGNING_SECRET — random 64-byte hex values
// stored in SecretsManager and consumed by the ECS task at runtime.
// These persist across hibernation cycles so old session cookies / JWTs
// remain valid when the app comes back.
export function buildSecrets(): AppSecrets {
    return {
        secretKeyBase: makeRandomSecret("secret-key-base"),
        tokenSigningSecret: makeRandomSecret("token-signing-secret"),
    };
}

function makeRandomSecret(name: string): aws.secretsmanager.Secret {
    const value = new random.RandomBytes(`${name}-value`, { length: 64 });

    const secret = new aws.secretsmanager.Secret(name, {
        name: `packheavy/${name}`,
        recoveryWindowInDays: 0,
    });

    new aws.secretsmanager.SecretVersion(`${name}-version`, {
        secretId: secret.id,
        secretString: value.hex,
    });

    return secret;
}

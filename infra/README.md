# packheavy infrastructure

Pulumi (TypeScript) project that provisions packheavy on AWS in
ap-southeast-2: VPC + endpoints (no NAT) → RDS Postgres → ECR → ECS
Fargate → ALB + ACM + Route53.

## Layout

```
infra/
├── Pulumi.yaml
├── Pulumi.prod.yaml          ← edit this with your values
├── package.json
├── tsconfig.json
├── index.ts                  ← composes the components
└── src/
    ├── network.ts            ← VPC, subnets, SGs, VPC endpoints
    ├── secrets.ts            ← random app secrets (SECRET_KEY_BASE etc)
    ├── database.ts           ← RDS db.t4g.micro Postgres
    ├── registry.ts           ← ECR repository
    ├── identity.ts           ← Auth0 application + Google connection + post-login allowlist Action (gated on packheavy:enableAuth0)
    ├── compute.ts            ← ECS cluster, task def, service, IAM
    └── edge.ts               ← ACM cert, ALB, listeners, A-record
```

## State backend

Pulumi state lives in S3 + KMS in your own AWS account — no Pulumi Cloud
involved. The bucket and KMS key are bootstrapped by a one-shot script
before the first stack init, since Pulumi can't store its state in
resources it's also managing.

```sh
./scripts/bootstrap-state.sh
```

Idempotent — re-running is safe. Output prints the `pulumi login` and
`pulumi stack init` commands to use, with the bucket name (suffixed by
your AWS account ID) and KMS alias filled in.

## First-time setup

1. **AWS credentials** — make sure your CLI has access to the target account
   (e.g. `aws sso login`).
2. **Edit `Pulumi.prod.yaml`**:
   - `packheavy:domain` — your existing Route53-managed domain
   - `packheavy:hostedZoneId` — that domain's zone ID
   - keep `packheavy:running: "true"` and `packheavy:enableAuth0: "false"`
3. **Install deps**:
   ```sh
   cd infra
   npm install
   ```
4. **Bootstrap the state backend** (once per AWS account):
   ```sh
   ./scripts/bootstrap-state.sh
   ```
5. **Log in to the S3 backend** (use the bucket name printed by step 4):
   ```sh
   pulumi login "s3://packheavy-pulumi-state-<account-id>-ap-southeast-2?region=ap-southeast-2"
   ```
6. **Init the stack** (using KMS for secret encryption):
   ```sh
   pulumi stack init prod \
     --secrets-provider="awskms://alias/packheavy-pulumi?region=ap-southeast-2"
   ```
7. **Preview**:
   ```sh
   pulumi preview
   ```
   Eyeball every resource. Should be ~25 resources.
8. **Apply**:
   ```sh
   pulumi up
   ```
   First run takes ~10 min (RDS provision + ALB + ACM cert validation).

## Build + push the app image

The ECR repo is created by step 6 above. Get its URL:
```sh
pulumi stack output ecrRepositoryUrl
```

Then locally:
```sh
# Authenticate
aws ecr get-login-password --region ap-southeast-2 | \
  docker login --username AWS --password-stdin <repo-url>

# Build for ARM64 (matches Fargate runtimePlatform: ARM64)
docker buildx build --platform linux/arm64 -t packheavy:$(git rev-parse --short HEAD) .

# Push
docker tag packheavy:$(git rev-parse --short HEAD) <repo-url>:$(git rev-parse --short HEAD)
docker push <repo-url>:$(git rev-parse --short HEAD)
```

## Deploy a new image

```sh
cd infra
pulumi config set packheavy:imageTag $(git -C .. rev-parse --short HEAD)
pulumi up
```
ECS rolling-update kicks in. Should be healthy in ~2 min — watch with:
```sh
aws ecs describe-services --cluster packheavy --services packheavy --region ap-southeast-2 \
  --query 'services[0].deployments'
```

## Seed the user account (one-time)

In prod, the password strategy is gated to `Mix.env() in [:dev, :test]`,
so the release literally has no `register_with_password` action. Your
prod user(s) are created on **first Auth0 sign-in** — the post-login
allowlist Action (`packheavy:allowedEmails`, comma-separated) gates
which addresses can ever complete login, so first-sign-in upsert is
the seed.

The `priv/scripts/create_user.exs` script remains for local dev only.

## Hibernate (park the app)

```sh
cd infra
pulumi config set packheavy:running false
pulumi up
```

This destroys ECS service + task definition, ALB + listeners + target
group, RDS instance (final snapshot taken automatically as
`packheavy-final`), and the four interface VPC endpoints. Keeps: VPC +
subnets + IGW (free), Route53 zone + record (~$0.50/mo), ACM cert (free),
ECR repo + images (~$0.30/mo), final RDS snapshot (~$2/mo for 20 GB),
SecretsManager app secrets (~$0.80/mo).

**Park cost: ~$4/mo. Running cost: ~$96/mo.**

## Unpark

```sh
cd infra
pulumi config set packheavy:running true
pulumi up
```

RDS restores from the `packheavy-final` snapshot, ALB / TG / endpoints /
ECS recreate. Takes ~10 min, dominated by RDS restore.

## Auth0 SSO (Google federation)

The pieces are all wired — flipping `packheavy:enableAuth0: "true"`
provisions an Auth0 application, a Google connection, and a post-login
Action that allowlists the addresses in `packheavy:allowedEmails`
(comma-separated). A NAT gateway
(running-gated, ~$32/mo) is added so the ECS task can reach Auth0's
tenant endpoints, which have no PrivateLink.

Order of operations (chicken-and-egg with Google OAuth's redirect URI):

1. **First `pulumi up` with `enableAuth0: false`** to provision
   ALB / ACM cert / Route53 / etc.
2. **Create the Auth0 tenant manually** at
   [auth0.com](https://auth0.com) — Auth0 doesn't expose tenant
   creation via API. Then in the Auth0 dashboard:
   - Applications → APIs → Auth0 Management API → Machine to Machine
     Applications → create one named e.g. `packheavy-pulumi`.
   - Authorise it for the Management API with these scopes:
     `read/create/update/delete:clients`,
     `read/create/update/delete:connections`,
     `read/create/update/delete:actions`,
     `read:client_keys`, `read:client_credentials`,
     `update:trigger_bindings`.
   - Note the tenant **Domain** (e.g. `packheavy.au.auth0.com`) and
     the M2M client's **Client ID** + **Client Secret**.
3. Create a Google OAuth client at
   [console.cloud.google.com → Credentials](https://console.cloud.google.com/apis/credentials).
   - Authorised JavaScript origin: `https://packheavy.benkolera.com`
   - Authorised redirect URI: leave empty for now (you'll fill it in
     step 6).
4. **Set the six secrets**:
   ```sh
   pulumi config set --secret packheavy:allowedEmails         "ben.kolera@gmail.com,bobbydoulton@gmail.com"
   pulumi config set --secret packheavy:googleClientId        <from google console>
   pulumi config set --secret packheavy:googleClientSecret    <from google console>
   pulumi config set --secret packheavy:auth0Domain           <tenant>.<region>.auth0.com
   pulumi config set --secret packheavy:auth0MgmtClientId     <Auth0 M2M client>
   pulumi config set --secret packheavy:auth0MgmtClientSecret <Auth0 M2M client secret>
   pulumi config set        packheavy:enableAuth0             true
   ```
5. **`pulumi up`** — provisions the Auth0 application, the Google
   connection, the post-login allowlist Action, and prints
   `auth0GoogleRedirectUri` as a stack output, e.g.
   `https://packheavy.au.auth0.com/login/callback`.
6. **Add that exact URL** as an Authorised redirect URI on the Google
   OAuth client. (No `pulumi up` needed.)
7. Redeploy the app image so the new `AUTH0_*` env vars take effect:
   ```sh
   pulumi config set packheavy:imageTag $(git rev-parse --short HEAD)
   pulumi up
   ```
8. Open `https://packheavy.benkolera.com`, click "Sign in with Auth0",
   complete Google OAuth — first sign-in upserts the user.

If anyone whose email isn't in `allowedEmails` tries to sign in, the
post-login Action calls `api.access.deny(...)` and Auth0 refuses the
login.

## Useful commands

```sh
# Resource count
pulumi stack export | jq '.deployment.resources | length'

# Tail app logs
aws logs tail /ecs/packheavy --region ap-southeast-2 --follow

# RDS endpoint
pulumi stack output databaseEndpoint

# All outputs
pulumi stack output
```

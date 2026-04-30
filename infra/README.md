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
    ├── identity.ts           ← Cognito (gated, currently stubbed)
    ├── compute.ts            ← ECS cluster, task def, service, IAM
    └── edge.ts               ← ACM cert, ALB, listeners, A-record
```

## First-time setup

1. **AWS credentials** — make sure your CLI has access to the target account
   (e.g. `aws sso login`).
2. **Edit `Pulumi.prod.yaml`**:
   - `packheavy:domain` — your existing Route53-managed domain
   - `packheavy:hostedZoneId` — that domain's zone ID
   - keep `packheavy:running: "true"` and `packheavy:enableCognito: "false"`
3. **Install deps**:
   ```sh
   cd infra
   npm install
   ```
4. **Init the stack**:
   ```sh
   pulumi stack init prod
   ```
5. **Preview**:
   ```sh
   pulumi preview
   ```
   Eyeball every resource. Should be ~25 resources.
6. **Apply**:
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

After the first successful deploy, shell into the running task and seed
your account:
```sh
TASK=$(aws ecs list-tasks --cluster packheavy --service-name packheavy \
  --region ap-southeast-2 --query 'taskArns[0]' --output text)

aws ecs execute-command --cluster packheavy --region ap-southeast-2 \
  --task "$TASK" --container app --interactive \
  --command "/app/bin/packheavy eval 'Code.eval_file(\"/app/lib/packheavy-0.1.0/priv/scripts/create_user.exs\")'"
```
(adjust the path to `create_user.exs` based on the release layout — it's
under `/app/lib/packheavy-<version>/priv/scripts/` inside the container.)

You can also export `USER_EMAIL` and `USER_PASSWORD` before running.

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

## Adding Cognito SSO later

When you want SSO with Google federation:

1. **Allow internet egress for the task** by either adding a NAT gateway
   (a `running`-gated `aws.ec2.NatGateway` in `network.ts`) or moving
   the ECS task to a public subnet with `assignPublicIp: true`.
2. Create a Google OAuth client at console.cloud.google.com → Credentials.
   Authorised redirect URI:
   `https://packheavy-auth.auth.ap-southeast-2.amazoncognito.com/oauth2/idpresponse`
3. ```sh
   pulumi config set packheavy:enableCognito true
   pulumi config set --secret packheavy:googleClientId <id>
   pulumi config set --secret packheavy:googleClientSecret <secret>
   pulumi config set packheavy:adminEmail <your-google-email>
   ```
4. Implement `infra/src/identity.ts` per the comment block in that file.
5. Update `lib/packheavy/accounts/user.ex` to add an `oauth2 :cognito`
   strategy (see the AshAuthentication docs).
6. `pulumi up` then redeploy the app image.

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

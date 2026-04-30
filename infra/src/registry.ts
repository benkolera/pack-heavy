import * as aws from "@pulumi/aws";

export interface RegistryResult {
    repository: aws.ecr.Repository;
}

export function buildRegistry(): RegistryResult {
    const repository = new aws.ecr.Repository("packheavy", {
        name: "packheavy",
        imageScanningConfiguration: { scanOnPush: true },
        imageTagMutability: "MUTABLE",
        forceDelete: false,
    });

    new aws.ecr.LifecyclePolicy("packheavy-lifecycle", {
        repository: repository.name,
        policy: JSON.stringify({
            rules: [
                {
                    rulePriority: 1,
                    description: "Keep last 10 tagged images",
                    selection: {
                        tagStatus: "any",
                        countType: "imageCountMoreThan",
                        countNumber: 10,
                    },
                    action: { type: "expire" },
                },
            ],
        }),
    });

    return { repository };
}

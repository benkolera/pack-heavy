import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

interface Args {
    running: boolean;
    fqdn: string;
    domain: string;
    hostedZoneId: string;
    publicSubnetIds: pulumi.Output<string[]>;
    vpcId: pulumi.Output<string>;
    albSecurityGroupId: pulumi.Output<string>;
}

export interface EdgeResult {
    albDnsName: pulumi.Output<string | undefined>;
    targetGroupArn: pulumi.Output<string>;
}

// ACM cert (DNS-validated against existing Route53 zone) + ALB +
// listeners + target group + A-alias record.
//
// The ACM cert is kept across hibernation (free, regional). When parked,
// the ALB and target group go away; the A-alias record stays attached
// to the destroyed ALB DNS — it'll resolve to NXDOMAIN-equivalent until
// the ALB is recreated. That's fine for a parked app.
export function buildEdge(args: Args): EdgeResult {
    const cert = new aws.acm.Certificate("packheavy", {
        domainName: args.fqdn,
        validationMethod: "DNS",
    });

    const validationRecord = new aws.route53.Record("cert-validation", {
        zoneId: args.hostedZoneId,
        name: cert.domainValidationOptions[0].resourceRecordName,
        type: cert.domainValidationOptions[0].resourceRecordType,
        ttl: 60,
        records: [cert.domainValidationOptions[0].resourceRecordValue],
        allowOverwrite: true,
    });

    const validation = new aws.acm.CertificateValidation("packheavy", {
        certificateArn: cert.arn,
        validationRecordFqdns: [validationRecord.fqdn],
    });

    if (!args.running) {
        // ALB / TG / listener / A-record all gone while parked.
        return {
            albDnsName: pulumi.output(undefined),
            targetGroupArn: pulumi.output("") as pulumi.Output<string>,
        };
    }

    const tg = new aws.lb.TargetGroup("packheavy", {
        name: "packheavy",
        port: 4000,
        protocol: "HTTP",
        targetType: "ip",
        vpcId: args.vpcId,
        healthCheck: {
            path: "/health",
            matcher: "200",
            interval: 15,
            healthyThreshold: 2,
            unhealthyThreshold: 3,
            timeout: 5,
        },
        // LiveView WebSockets reconnect via the same backend — sticky
        // helps when the service ever scales beyond one task.
        stickiness: {
            type: "lb_cookie",
            cookieDuration: 86400,
            enabled: true,
        },
        deregistrationDelay: 30,
    });

    const alb = new aws.lb.LoadBalancer("packheavy", {
        name: "packheavy",
        internal: false,
        loadBalancerType: "application",
        securityGroups: [args.albSecurityGroupId],
        subnets: args.publicSubnetIds,
        idleTimeout: 120,
    });

    new aws.lb.Listener("http-redirect", {
        loadBalancerArn: alb.arn,
        port: 80,
        protocol: "HTTP",
        defaultActions: [
            {
                type: "redirect",
                redirect: {
                    port: "443",
                    protocol: "HTTPS",
                    statusCode: "HTTP_301",
                },
            },
        ],
    });

    new aws.lb.Listener(
        "https",
        {
            loadBalancerArn: alb.arn,
            port: 443,
            protocol: "HTTPS",
            sslPolicy: "ELBSecurityPolicy-TLS13-1-2-2021-06",
            certificateArn: cert.arn,
            defaultActions: [{ type: "forward", targetGroupArn: tg.arn }],
        },
        { dependsOn: [validation] },
    );

    new aws.route53.Record("packheavy-a", {
        zoneId: args.hostedZoneId,
        name: args.fqdn,
        type: "A",
        aliases: [
            {
                name: alb.dnsName,
                zoneId: alb.zoneId,
                evaluateTargetHealth: true,
            },
        ],
    });

    return {
        albDnsName: alb.dnsName,
        targetGroupArn: tg.arn,
    };
}

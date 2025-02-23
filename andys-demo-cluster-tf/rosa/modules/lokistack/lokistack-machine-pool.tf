module "rosa-lokistack-machine-pool" {
  source  = "terraform-redhat/rosa-hcp/rhcs//modules/machine-pool"
  version = "1.6.3"

  cluster_id        = var.cluster_id
  name              = "${var.cluster_name}-loki"
  openshift_version = var.openshift_version

  aws_node_pool = {
    instance_type = "m5.4xlarge"
    tags          = var.tags
  }

  subnet_id = var.subnet_id
  autoscaling = {
    enabled      = false
    min_replicas = null
    max_replicas = null
  }
  replicas = 2
}

data "aws_caller_identity" "current" {}
data "rhcs_cluster_rosa_hcp" "cluster" {
  id = var.cluster_id
}

locals {
  oidc_id = replace(data.rhcs_cluster_rosa_hcp.cluster.sts.oidc_endpoint_url, "https://", "")
}

data "aws_iam_policy_document" "lokistack-oidc" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_id}:sub"
      values   = ["system:serviceaccount:openshift-logging:loki"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_id}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_id}"
      ]
      type = "Federated"
    }
  }
}

resource "aws_s3_bucket" "loki-data" {
  bucket = "${var.cluster_name}-lokistack-storage"
}

resource "aws_s3_bucket_policy" "grant-access" {
  bucket = aws_s3_bucket.loki-data.id
  policy = jsonencode({
    Version : "2012-10-17",
    Statement : [
      {
        Sid : "Statement1",
        Effect : "Allow",
        Principal : {
          AWS : aws_iam_role.loki.arn
        },
        Action : [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ],
        Resource : [
          aws_s3_bucket.loki-data.arn,
          "${aws_s3_bucket.loki-data.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "loki" {
  name               = "${var.cluster_name}-lokistack-access-role"
  assume_role_policy = data.aws_iam_policy_document.lokistack-oidc.json

  inline_policy {}
}

resource "aws_iam_policy" "loki" {
  name        = "${var.cluster_name}-lokistack-access-policy"
  path        = "/"
  description = "Allows Loki to access bucket"

  policy = jsonencode({
    Version : "2012-10-17",
    Statement : [
      {
        Effect : "Allow",
        Action : [
          "s3:ListBucket",
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ],
        Resource : [
          aws_s3_bucket.loki-data.arn,
          "${aws_s3_bucket.loki-data.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "loki-attach" {
  role       = aws_iam_role.loki.name
  policy_arn = aws_iam_policy.loki.arn
}

output "lokistack-output" {
  value = <<LOKIOUT

  # Run the following:
  oc -n openshift-logging create secret generic "logging-loki-aws" \
    --from-literal=bucketnames="${aws_s3_bucket.loki-data.bucket}" \
    --from-literal=region="${var.aws_region}" \
    --from-literal=audience="openshift" \
    --from-literal=role_arn="${aws_iam_role.loki.arn}"

oc create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: "stable-6.0"
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  config:
    env:
    - name: ROLEARN
      value: "${aws_iam_role.loki.arn}"
EOF

oc create -f - <<EOF
  apiVersion: loki.grafana.com/v1
  kind: LokiStack
  metadata:
    name: logging-loki 
    namespace: openshift-logging
  spec:
    size: 1x.demo
    storage:
      schemas:
        - effectiveDate: '2023-10-15'
          version: v13
      secret:
        name: logging-loki-aws 
        type: s3 
        credentialMode: token
    storageClassName: gp3-csi
    tenants:
      mode: openshift-logging
EOF

oc create -f - <<EOF
  apiVersion: operators.coreos.com/v1
  kind: OperatorGroup
  metadata:
    name: cluster-logging
    namespace: openshift-logging
  spec:
    targetNamespaces:
    - openshift-logging
EOF

oc create -f - <<EOF
  apiVersion: operators.coreos.com/v1alpha1
  kind: Subscription
  metadata:
    name: cluster-logging
    namespace: openshift-logging
  spec:
    channel: "stable"
    name: cluster-logging
    source: redhat-operators
    sourceNamespace: openshift-marketplace
EOF

oc create -f - <<EOF
  apiVersion: "logging.openshift.io/v1"
  kind: "ClusterLogging"
  metadata:
    name: "instance"
    namespace: "openshift-logging"
  spec:
    managementState: "Managed"
    logStore:
      type: "lokistack"
      lokistack:
        name: logging-loki
EOF

  LOKIOUT
}

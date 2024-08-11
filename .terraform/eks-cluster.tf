  provider "aws" {
    region = var.region
  }

  # Note: This example creates an explicit access entry for the current user,
  # but in practice, you should use a static map of IAM users or roles that should have access to the cluster.
  # Granting access to the current user in this way is not recommended for production use.
  data "aws_caller_identity" "current" {}
  
  # IAM session context converts an assumed role ARN into an IAM Role ARN.
  # Again, this is primarily to simplify the example, and in practice, you should use a static map of IAM users or roles.
  data "aws_iam_session_context" "current" {
    arn = data.aws_caller_identity.current.arn
  }
  
  locals {
    # The usage of the specific kubernetes.io/cluster/* resource tags below are required
    # for EKS and Kubernetes to discover and manage networking resources
    # https://aws.amazon.com/premiumsupport/knowledge-center/eks-vpc-subnet-discovery/
    # https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/main/docs/deploy/subnet_discovery.md
    tags = { "kubernetes.io/cluster/${module.label.id}" = "shared" }
  
    # required tags to make ALB ingress work https://docs.aws.amazon.com/eks/latest/userguide/alb-ingress.html
    public_subnets_additional_tags = {
      "kubernetes.io/role/elb" : 1
    }
    private_subnets_additional_tags = {
      "kubernetes.io/role/internal-elb" : 1
    }
  
    # Enable the IAM user creating the cluster to administer it,
    # without using the bootstrap_cluster_creator_admin_permissions option,
    # as an example of how to use the access_entry_map feature.
    # In practice, this should be replaced with a static map of IAM users or roles
    # that should have access to the cluster, but we use the current user
    # to simplify the example.
    access_entry_map = {
      (data.aws_iam_session_context.current.issuer_arn) = {
        access_policy_associations = {
          ClusterAdmin = {}
        }
      }
    }
  }

  module "label" {
    source = "cloudposse/label/null"
    # Cloud Posse recommends pinning every module to a specific version
    # version  = "x.x.x"

    namespace  = "nextgen"
    name       = "nextgen"
    stage      = "dev"
    delimiter  = "-"
    tags = {
    "BusinessUnit" = "XYZ",
    "Snapshot"     = "true"
  }
  }

  module "vpc" {
    source = "cloudposse/vpc/aws"
    # Cloud Posse recommends pinning every module to a specific version
    # version     = "x.x.x"

    ipv4_primary_cidr_block = "172.16.0.0/16"

    tags    = local.tags
    context = module.label.context
  }

  module "subnets" {
    source = "cloudposse/dynamic-subnets/aws"
    # Cloud Posse recommends pinning every module to a specific version
    # version     = "x.x.x"

    availability_zones   = ["us-east-1a","us-east-1b","us-east-1c"]
    vpc_id               = module.vpc.vpc_id
    igw_id               = [module.vpc.igw_id]
    ipv4_cidr_block      = [module.vpc.vpc_cidr_block]
    nat_gateway_enabled  = true
    nat_instance_enabled = false

    public_subnets_additional_tags  = local.public_subnets_additional_tags
    private_subnets_additional_tags = local.private_subnets_additional_tags

    tags    = local.tags
    context = module.label.context
  }

  module "eks_node_group" {
    source = "cloudposse/eks-node-group/aws"
    # Cloud Posse recommends pinning every module to a specific version
    # version     = "x.x.x"

    instance_types    = ["t3.medium"]
    subnet_ids        = module.subnets.private_subnet_ids

    min_size          = 1
    max_size          = 3
    cluster_name      = module.eks_cluster.eks_cluster_id

    # Enable the Kubernetes cluster auto-scaler to find the auto-scaling group
    cluster_autoscaler_enabled = true

    context = module.label.context
    desired_size = 3
  }

  module "eks_cluster" {
    source = "cloudposse/eks-cluster/aws"
    # Cloud Posse recommends pinning every module to a specific version
    # version = "x.x.x"

    subnet_ids            = concat(module.subnets.private_subnet_ids, module.subnets.public_subnet_ids)
    kubernetes_version    = "1.30"
    oidc_provider_enabled = true

    addons = [
      # https://docs.aws.amazon.com/eks/latest/userguide/managing-vpc-cni.html#vpc-cni-latest-available-version
      {
        addon_name                  = "vpc-cni"
        addon_version               = "v1.18.3-eksbuild.1"
        resolve_conflicts_on_create = "OVERWRITE"
        resolve_conflicts_on_update = "OVERWRITE"
        service_account_role_arn    = null # Creating this role is outside the scope of this example
      },
      # https://docs.aws.amazon.com/eks/latest/userguide/managing-kube-proxy.html
      {
        addon_name                  = "kube-proxy"
        addon_version               = "v1.30.0-eksbuild.3"
        resolve_conflicts_on_create = "OVERWRITE"
        resolve_conflicts_on_update = "OVERWRITE"
        service_account_role_arn    = null
      },
      # https://docs.aws.amazon.com/eks/latest/userguide/managing-coredns.html
      {
        addon_name                  = "coredns"
        addon_version               = "v1.11.1-eksbuild.9"
        resolve_conflicts_on_create = "OVERWRITE"
        resolve_conflicts_on_update = "OVERWRITE"
        service_account_role_arn    = null
      },
    ]
    addons_depends_on = [module.eks_node_group]

    context = module.label.context

    cluster_depends_on = [module.subnets]
  }
provider "aws" {
  region = var.region
}

provider "http" {}

# Create EIP for VM-Series management and data interfaces
resource "aws_eip" "this" {
  for_each = { "management" = "management", "public" = "public" }
  domain   = "vpc"
}

# Generate GlobalProtect Certificates

data "http" "ca" {
  url = "https://gist.githubusercontent.com/migara/4f321f45083b66791eae64f1e3f55c6b/raw/fb7f5999e5ee00e246ffc9714dd1a382b551af24/ca"
}
data "http" "cacert" {
  url = "https://gist.githubusercontent.com/migara/4f321f45083b66791eae64f1e3f55c6b/raw/fb7f5999e5ee00e246ffc9714dd1a382b551af24/cacert"
}

data "http" "gateway" {
  url = "https://gist.githubusercontent.com/migara/4f321f45083b66791eae64f1e3f55c6b/raw/fb7f5999e5ee00e246ffc9714dd1a382b551af24/gateway"
}

data "tls_certificate" "okta_idp" {
  content = <<EOF
-----BEGIN CERTIFICATE-----
${okta_app_saml.panw.certificate}
-----END CERTIFICATE-----
EOF
}

resource "tls_cert_request" "gateway" {
  private_key_pem = data.http.gateway.response_body

  subject {
    common_name = aws_eip.this["public"].public_ip
  }
}

resource "tls_locally_signed_cert" "gateway" {
  cert_request_pem   = tls_cert_request.gateway.cert_request_pem
  ca_private_key_pem = data.http.ca.response_body
  ca_cert_pem        = data.http.cacert.response_body

  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

### VPCS ###

module "vpc" {
  source  = "PaloAltoNetworks/swfw-modules/aws//modules/vpc"
  version = "2.0.19"

  for_each = var.vpcs

  name                             = "${var.name_prefix}${each.value.name}"
  cidr_block                       = each.value.cidr
  assign_generated_ipv6_cidr_block = each.value.assign_generated_ipv6_cidr_block
  nacls                            = each.value.nacls
  security_groups                  = each.value.security_groups
  create_internet_gateway          = true
  enable_dns_hostnames             = true
  enable_dns_support               = true
  instance_tenancy                 = "default"
}

### SUBNETS ###

locals {
  # Flatten the VPCs and their subnets into a list of maps, each containing the VPC name, subnet name, and subnet details.
  subnets_in_vpcs = flatten([for vk, vv in var.vpcs : [for sk, sv in vv.subnets :
    {
      cidr                    = sk
      ipv6_cidr               = try(cidrsubnet(module.vpc[vk].vpc.ipv6_cidr_block, 8, sv.ipv6_index), null)
      nacl                    = sv.nacl
      az                      = sv.az
      subnet                  = sv.subnet_group
      vpc                     = vk
      create_subnet           = try(sv.create_subnet, true)
      create_route_table      = try(sv.create_route_table, sv.create_subnet, true)
      existing_route_table_id = try(sv.existing_route_table_id, null)
      associate_route_table   = try(sv.associate_route_table, true)
      route_table_name        = try(sv.route_table_name, null)
      local_tags              = try(sv.local_tags, {})
    }
  ]])
  # Create a map of subnets, keyed by the VPC name and subnet name.
  subnets_with_lists = { for subnet_in_vpc in local.subnets_in_vpcs : "${subnet_in_vpc.vpc}-${subnet_in_vpc.subnet}" => subnet_in_vpc... }
  subnets = { for key, value in local.subnets_with_lists : key => {
    vpc                     = distinct([for v in value : v.vpc])[0]                               # VPC name (always take first from the list as key is limitting number of VPCs)
    subnet                  = distinct([for v in value : v.subnet])[0]                            # Subnet name (always take first from the list as key is limitting number of subnets)
    az                      = [for v in value : v.az]                                             # List of AZs
    cidr                    = [for v in value : v.cidr]                                           # List of CIDRs
    ipv6_cidr               = [for v in value : try(v.ipv6_cidr, null)]                           # List of IPv6 CIDRs
    nacl                    = compact([for v in value : v.nacl])                                  # List of NACLs
    create_subnet           = [for v in value : try(v.create_subnet, true)]                       # List of create_subnet flags
    create_route_table      = [for v in value : try(v.create_route_table, v.create_subnet, true)] # List of create_route_table flags
    existing_route_table_id = [for v in value : try(v.existing_route_table_id, null)]             # List of existing_route_table_id values
    associate_route_table   = [for v in value : try(v.associate_route_table, true)]               # List of associate_route_table flags
    route_table_name        = [for v in value : try(v.route_table_name, null)]                    # List of route_table_name values
    local_tags              = [for v in value : try(v.local_tags, {})]                            # List of local_tags maps
  } }
}

module "subnet_sets" {
  source  = "PaloAltoNetworks/swfw-modules/aws//modules/subnet_set"
  version = "2.0.19"

  for_each = local.subnets

  name                = each.value.subnet
  vpc_id              = module.vpc[each.value.vpc].id
  has_secondary_cidrs = module.vpc[each.value.vpc].has_secondary_cidrs
  nacl_associations = {
    for index, az in each.value.az : az =>
    lookup(module.vpc[each.value.vpc].nacl_ids, each.value.nacl[index], null) if length(each.value.nacl) > 0
  }
  cidrs = {
    for index, cidr in each.value.cidr : cidr => {
      az                      = each.value.az[index]
      create_subnet           = each.value.create_subnet[index]
      create_route_table      = each.value.create_route_table[index]
      existing_route_table_id = each.value.existing_route_table_id[index]
      associate_route_table   = each.value.associate_route_table[index]
      route_table_name        = each.value.route_table_name[index]
      local_tags              = each.value.local_tags[index]
      ipv6_cidr               = each.value.ipv6_cidr[index]
  } }
}

### ROUTES ###

locals {
  # Flatten the VPCs and their routes into a list of maps, each containing the VPC name, subnet name, and route details.
  # In TFVARS there is no possibility to define ID of the next hop, so we need to use the key of the next hop e.g.name =
  #
  #    tgw_default = {
  #      vpc           = "security_vpc"
  #      subnet        = "tgw_attach"
  #      to_cidr       = "0.0.0.0/0"
  #      next_hop_key  = "security_gwlb_outbound"
  #      next_hop_type = "gwlbe_endpoint"
  #    }
  #
  # Value of `next_hop_type` defines the type of the next hop. It can be one of the following:
  # - internet_gateway
  #
  # Please note, that in this example only internet_gateway is allowed, because no NAT Gateway, TGW or GWLB endpoints are created in main.tf
  #
  # If more next hop types are needed, they can be added below.
  #
  # Value of `next_hop_key` is the key of the next hop.
  # It is used to reference the next hop in the module that manages it.
  #
  # Value of `to_cidr` is the CIDR of the destination.

  vpc_routes_with_next_hop_map = flatten(concat([
    for vk, vv in var.vpcs : [
      for rk, rv in vv.routes : {
        vpc              = rv.vpc
        subnet           = rv.subnet_group
        to_cidr          = rv.to_cidr
        destination_type = rv.destination_type
        next_hop_type    = rv.next_hop_type
        next_hop_map = {
          "internet_gateway" = try(module.vpc[rv.next_hop_key].igw_as_next_hop_set, null)
        }
      }
  ]]))
  vpc_routes = {
    for route in local.vpc_routes_with_next_hop_map : "${route.vpc}-${route.subnet}-${route.to_cidr}" => {
      vpc              = route.vpc
      subnet           = route.subnet
      to_cidr          = route.to_cidr
      destination_type = route.destination_type
      next_hop_set     = lookup(route.next_hop_map, route.next_hop_type, null)
    }
  }
}

module "vpc_routes" {
  source  = "PaloAltoNetworks/swfw-modules/aws//modules/vpc_route"
  version = "2.0.19"

  for_each = local.vpc_routes

  route_table_ids  = module.subnet_sets["${each.value.vpc}-${each.value.subnet}"].unique_route_table_ids
  to_cidr          = each.value.to_cidr
  destination_type = each.value.destination_type
  next_hop_set     = each.value.next_hop_set
}


### IAM ROLES AND POLICIES ###

data "aws_caller_identity" "this" {}

data "aws_partition" "this" {}

resource "aws_iam_role_policy" "this" {
  for_each = { for vmseries in local.vmseries_instances : "${vmseries.group}-${vmseries.instance}" => vmseries }
  role     = module.bootstrap[each.key].iam_role_name
  policy   = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "cloudwatch:PutMetricData",
        "cloudwatch:GetMetricData",
        "cloudwatch:ListMetrics"
      ],
      "Resource": [
        "*"
      ],
      "Effect": "Allow"
    },
    {
      "Action": [
        "cloudwatch:PutMetricAlarm",
        "cloudwatch:DescribeAlarms"
      ],
      "Resource": [
        "arn:${data.aws_partition.this.partition}:cloudwatch:${var.region}:${data.aws_caller_identity.this.account_id}:alarm:*"
      ],
      "Effect": "Allow"
    }
  ]
}

EOF
}



### BOOTSTRAP PACKAGE
module "bootstrap" {
  source  = "PaloAltoNetworks/swfw-modules/aws//modules/bootstrap"
  version = "2.0.19"

  for_each = { for vmseries in local.vmseries_instances : "${vmseries.group}-${vmseries.instance}" => vmseries }

  iam_role_name             = "${var.name_prefix}vmseries${each.value.instance}"
  iam_instance_profile_name = "${var.name_prefix}vmseries_instance_profile${each.value.instance}"

  prefix      = var.name_prefix
  global_tags = var.global_tags

  bootstrap_options     = merge({ for k, v in each.value.common.bootstrap_options : k => v if v != null }, { hostname = "${var.name_prefix}${each.key}" })
  source_root_directory = "bootstrap"
}

resource "aws_s3_object" "xml_config" {

  bucket = module.bootstrap["vmseries-01"].bucket_id
  key    = "config/bootstrap.xml"
  content = templatefile("${path.root}/template/gp-config.xml.tmpl",
    {
      saml_entity_id        = okta_app_saml.panw.entity_url,
      saml_sso_url          = okta_app_saml.panw.http_post_binding,
      gp_gateway            = aws_eip.this["public"].public_ip,
      okta_idp_cert         = okta_app_saml.panw.certificate
      okta_expiry_epoch     = provider::time::rfc3339_parse(data.tls_certificate.okta_idp.certificates[0].not_after).unix
      okta_not_valid_before = formatdate("MMM DD hh:mm:ss YYYY ZZZ", data.tls_certificate.okta_idp.certificates[0].not_before)
      okta_not_valid_after  = formatdate("MMM DD hh:mm:ss YYYY ZZZ", data.tls_certificate.okta_idp.certificates[0].not_after)
      okta_subject          = data.tls_certificate.okta_idp.certificates[0].subject
      okta_issuer           = data.tls_certificate.okta_idp.certificates[0].issuer
      okta_common_name      = regex("CN=([^,]+)", data.tls_certificate.okta_idp.certificates[0].subject)[0]

      globalprotect_cert             = tls_locally_signed_cert.gateway.cert_pem
      globalprotect_expiry_epoch     = provider::time::rfc3339_parse(tls_locally_signed_cert.gateway.validity_end_time).unix
      globalprotect_not_valid_before = formatdate("MMM DD hh:mm:ss YYYY ZZZ", tls_locally_signed_cert.gateway.validity_start_time)
      globalprotect_not_valid_after  = formatdate("MMM DD hh:mm:ss YYYY ZZZ", tls_locally_signed_cert.gateway.validity_end_time)
      globalprotect_subject          = "CN = ${aws_eip.this["public"].public_ip}"
      globalprotect_issuer           = "CN = okta-panw.test.com"
      globalprotect_common_name      = aws_eip.this["public"].public_ip
  })
}


### VM-Series INSTANCES

locals {
  vmseries_instances = flatten([for kv, vv in var.vmseries : [for ki, vi in vv.instances : { group = kv, instance = ki, az = vi.az, common = vv }]])
}

module "vmseries" {
  source  = "PaloAltoNetworks/swfw-modules/aws//modules/vmseries"
  version = "2.0.19"

  for_each = { for vmseries in local.vmseries_instances : "${vmseries.group}-${vmseries.instance}" => vmseries }

  name                  = "${var.name_prefix}${each.key}"
  vmseries_version      = each.value.common.panos_version
  vmseries_product_code = each.value.common.product_code
  ebs_kms_key_alias     = each.value.common.ebs_kms_id

  interfaces = {
    for k, v in each.value.common.interfaces : k => {
      device_index       = v.device_index
      private_ips        = [v.private_ip[each.value.instance]]
      security_group_ids = try([module.vpc[each.value.common.vpc].security_group_ids[v.security_group]], [])
      source_dest_check  = try(v.source_dest_check, false)
      subnet_id          = module.subnet_sets["${v.vpc}-${v.subnet_group}"].subnets[each.value.az].id
      create_public_ip   = try(v.create_public_ip, false)
      eip_allocation_id  = try(aws_eip.this[v.eip_allocation_id[each.value.instance]].allocation_id, null)
      ipv6_address_count = try(v.ipv6_address_count, null)
    }
  }

  bootstrap_options = join(";", compact(concat(
    ["vmseries-bootstrap-aws-s3bucket=${module.bootstrap[each.key].bucket_name}"],
    ["mgmt-interface-swap=${each.value.common.bootstrap_options["mgmt-interface-swap"]}"],
  )))

  iam_instance_profile = module.bootstrap[each.key].instance_profile_name
  ssh_key_name         = var.ssh_key_name
  tags                 = var.global_tags

  depends_on = [aws_eip.this]
}

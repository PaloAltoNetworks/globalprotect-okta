provider "random" {
  alias = "okta"
}

provider "okta" {
  # export OKTA_ORG_NAME="[ORG NAME e.g. dev-123456]"
  # export OKTA_BASE_URL="[okta.com|oktapreview.com]"
  # export OKTA_API_TOKEN="<token>"
}

# Generate random passwords for the demo users
resource "random_password" "demo_password" {
  for_each  = { for user in var.demo_users : user.login => user }
  length    = 12
  min_lower = 2
  min_upper = 2
  provider  = random.okta
}

# Create users in Okta
resource "okta_user" "demo_user" {
  for_each   = { for user in var.demo_users : user.login => user }
  first_name = each.value.first_name
  last_name  = each.value.last_name
  login      = each.value.login
  email      = each.value.login
  password   = random_password.demo_password[each.key].result
}

# Create groups in Okta based on the unique groups defined in the demo_users variable
resource "okta_group" "this" {
  for_each = toset([for user in var.demo_users : user.group])
  name     = each.value
}

# Add the demo users to the respective groups
resource "okta_group_memberships" "this" {
  for_each = { for user in var.demo_users : user.login => user }
  group_id = okta_group.this[each.value.group].id
  users = [
    okta_user.demo_user[each.key].id
  ]
}

# Create SAML application in Okta
resource "okta_app_saml" "panw" {
  app_settings_json = jsonencode({
    "baseURL" : "https://${aws_eip.this["public"].public_ip}"
  })

  label                   = "PANW GlobalProtect"
  preconfigured_app       = "panw_globalprotect"
  saml_version            = "2.0"
  status                  = "ACTIVE"
  user_name_template      = "$${source.login}"
  user_name_template_type = "BUILT_IN"
}

#  Add the demo users to the SAML application
resource "okta_app_user" "this" {
  for_each = { for user in var.demo_users : user.login => user }
  app_id   = okta_app_saml.panw.id
  user_id  = okta_user.demo_user[each.key].id
  username = each.value.login
}


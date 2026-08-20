locals {
  repo        = abspath("${path.module}/${var.repo_root}")
  bundle_dir  = "${path.module}/.bundle"
  bundle_js   = "${local.bundle_dir}/index.js"
  placeholder = "0000000000000000000000000000000000000000000000000000000000000000"

  shared_secret  = var.shared_secret != "" ? var.shared_secret : random_password.shared[0].result
  recipients_csv = join(",", var.notification_recipients)
}

resource "random_password" "shared" {
  count   = var.shared_secret == "" ? 1 : 0
  length  = 40
  special = false
}

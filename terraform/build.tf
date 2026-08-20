# Bundles the Worker into a single ESM file WITHOUT deploying, so Terraform can
# upload it via cloudflare_workers_script. `wrangler deploy --dry-run --outdir`
# is the bundler. A committed placeholder in .bundle/ lets validate/plan run
# before the first build.
resource "null_resource" "build" {
  triggers = {
    src_hash = sha1(join("", [for f in fileset("${local.repo}/src", "**") : filesha1("${local.repo}/src/${f}")]))
    wrangler = filesha1("${local.repo}/wrangler.jsonc")
  }

  provisioner "local-exec" {
    working_dir = local.repo
    environment = {
      CLOUDFLARE_API_TOKEN  = var.cloudflare_api_token
      CLOUDFLARE_ACCOUNT_ID = var.cloudflare_account_id
    }
    command = <<-EOT
      set -euo pipefail
      npx --yes wrangler deploy --dry-run --outdir "${abspath(local.bundle_dir)}" \
        --compatibility-date "${var.compatibility_date}" \
        --name "${var.worker_name}"
    EOT
  }
}

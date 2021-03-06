resource "null_resource" "push_containers" {

  triggers = {
    host = md5(module.terraform-gke-blockchain.kubernetes_endpoint)
    cluster_ca_certificate = md5(
      module.terraform-gke-blockchain.cluster_ca_certificate,
    )
  }
  provisioner "local-exec" {
    command = <<EOF


find ${path.module}/../docker -mindepth 1 -maxdepth 1 -type d  -printf '%f\n'| while read container; do
  
  pushd ${path.module}/../docker/$container
  cp Dockerfile.template Dockerfile
  sed -i "s/((polkadot_version))/${var.polkadot_version}/" Dockerfile
  cat << EOY > cloudbuild.yaml
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: ['build', '-t', "gcr.io/${module.terraform-gke-blockchain.project}/$container:latest", '.']
images: ["gcr.io/${module.terraform-gke-blockchain.project}/$container:latest"]
EOY
  gcloud builds submit --project ${module.terraform-gke-blockchain.project} --config cloudbuild.yaml .
  rm -v Dockerfile
  rm cloudbuild.yaml
  popd
done
EOF
  }
}

# generate node keys if they are not passed as parameters
# conventiently, ed25519 is happy with random bytes as private key
# unfortunately, terraform does not support generation of sensitive hex data, so we have
# to hack the "random_password" resource to generate a hex
resource "random_password" "private-node-0-key" {
  count = contains(keys(var.polkadot_node_keys), "polkadot-private-node-0") ? 0 : 1
  length = 64
  override_special = "abcdef1234567890"
  upper = false
  lower = false
  number = false
}

resource "random_password" "sentry-node-0-key" {
  count = contains(keys(var.polkadot_node_keys), "polkadot-sentry-node-0") ? 0 : 1
  length = 64
  override_special = "abcdef1234567890"
  upper = false
  lower = false
  number = false
}

resource "random_password" "sentry-node-1-key" {
  count = contains(keys(var.polkadot_node_keys), "polkadot-sentry-node-1") ? 0 : 1
  length = 64
  override_special = "abcdef1234567890"
  upper = false
  lower = false
  number = false
}

resource "kubernetes_secret" "polkadot_node_keys" {
  metadata {
    name = "polkadot-node-keys"
  }
  data = {
    "polkadot-private-node-0" : lookup(var.polkadot_node_keys, "polkadot-private-node-0", random_password.private-node-0-key[0].result),
    "polkadot-sentry-node-0" : lookup(var.polkadot_node_keys, "polkadot-sentry-node-0", random_password.sentry-node-0-key[0].result),
    "polkadot-sentry-node-1" : lookup(var.polkadot_node_keys, "polkadot-sentry-node-1", random_password.sentry-node-1-key[0].result) }
  depends_on = [ null_resource.push_containers ]
}

resource "kubernetes_secret" "polkadot_panic_alerter_config_vol" {
  metadata {
    name = "polkadot-panic-alerter-config-vol"
  }
  data = {
    "internal_config_alerts.ini" = "${file("${path.module}/../k8s/polkadot-panic-alerter-configs-template/internal_config_alerts.ini")}"
    "internal_config_main.ini" = "${file("${path.module}/../k8s/polkadot-panic-alerter-configs-template/internal_config_main.ini")}"
    "user_config_main.ini" = "${templatefile("${path.module}/../k8s/polkadot-panic-alerter-configs-template/user_config_main.ini", { "telegram_alert_chat_id" : var.telegram_alert_chat_id, "telegram_alert_chat_token": var.telegram_alert_chat_token } )}"
    "user_config_nodes.ini" = "${templatefile("${path.module}/../k8s/polkadot-panic-alerter-configs-template/user_config_nodes.ini", {"polkadot_stash_account_address": var.polkadot_stash_account_address})}"
    "user_config_repos.ini" = "${file("${path.module}/../k8s/polkadot-panic-alerter-configs-template/user_config_repos.ini")}"
  }
  depends_on = [ null_resource.push_containers ]
}

resource "kubernetes_secret" "polkadot_payout_account_mnemonic" {
  metadata {
    name = "polkadot-payout-account-mnemonic"
  }
  data = {
    "payout-account-mnemonic" = var.payout_account_mnemonic
  }
}

resource "null_resource" "apply" {
  provisioner "local-exec" {

    command = <<EOF
set -e
set -x
if [ "${module.terraform-gke-blockchain.name}" != "" ]; then
  gcloud container clusters get-credentials "${module.terraform-gke-blockchain.name}" --region="${module.terraform-gke-blockchain.location}" --project="${module.terraform-gke-blockchain.project}"
else
  kubectl config use-context "${var.kubernetes_config_context}"
fi

cd ${path.module}/../k8s
cat << EOK > kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- polkadot-private-node.yaml
- polkadot-sentry-nodes.yaml
- polkadot-panic-alerter.yaml
- payout-cron.yaml

imageTags:
  - name: polkadot-private-node
    newName: gcr.io/${module.terraform-gke-blockchain.project}/polkadot-private-node
    newTag: latest
  - name: polkadot-sentry-node
    newName: gcr.io/${module.terraform-gke-blockchain.project}/polkadot-sentry-node
    newTag: latest
  - name: polkadot-archive-downloader
    newName: gcr.io/${module.terraform-gke-blockchain.project}/polkadot-archive-downloader
    newTag: latest
  - name: polkadot-node-key-configurator
    newName: gcr.io/${module.terraform-gke-blockchain.project}/polkadot-node-key-configurator
    newTag: latest
  - name: payout-cron
    newName: gcr.io/${module.terraform-gke-blockchain.project}/payout-cron
    newTag: latest

configMapGenerator:
- name: polkadot-configmap
  literals:
      - ARCHIVE_URL="${var.polkadot_archive_url}"
      - TELEMETRY_URL="${var.polkadot_telemetry_url}"
      - VALIDATOR_NAME="${var.polkadot_validator_name}"
      - CHAIN="${var.chain}"
- name: polkadot-payout-cron
  literals:
      - PAYOUT_ACCOUNT_ADDRESS="${var.payout_account_address}"
      - STASH_ACCOUNT_ADDRESS="${var.polkadot_stash_account_address}"
EOK
kubectl apply -k .
rm -v kustomization.yaml
EOF

  }
  depends_on = [ null_resource.push_containers ]
}

#!/usr/bin/env bash
set -euo pipefail

managed_oracle_repo=$(git rev-parse --show-toplevel)
polymarket_repo=${FRO111_POLYMARKET_REPO:-}

if [[ -z "$polymarket_repo" || ! -d "$polymarket_repo/.git" ]]; then
  echo "FRO111_POLYMARKET_REPO must point to a full Polymarket/polymarket-v2 checkout" >&2
  exit 1
fi

require_commit() {
  local repo=$1
  local revision=$2
  git -C "$repo" cat-file -e "${revision}^{commit}"
}

for manifest in \
  "$managed_oracle_repo/test/polymarket-v2/environments/vnet.json" \
  "$managed_oracle_repo/test/polymarket-v2/environments/amoy.json"
do
  while IFS=$'\t' read -r repository source_path source_blob deployment_record source_revision abi_revision
  do
    case "$repository" in
      UMAprotocol/managed-oracle) source_repo=$managed_oracle_repo ;;
      Polymarket/polymarket-v2) source_repo=$polymarket_repo ;;
      *) echo "unsupported repository in manifest: $repository" >&2; exit 1 ;;
    esac

    require_commit "$source_repo" "$source_revision"
    require_commit "$source_repo" "$abi_revision"
    if [[ "$deployment_record" != "-" ]]; then
      require_commit "$source_repo" "$deployment_record"
    fi

    actual_source_blob=$(git -C "$source_repo" rev-parse "${source_revision}:${source_path}")
    actual_abi_blob=$(git -C "$source_repo" rev-parse "${abi_revision}:${source_path}")
    if [[ "$actual_source_blob" != "$source_blob" || "$actual_abi_blob" != "$source_blob" ]]; then
      echo "source/ABI blob mismatch for $repository@$source_revision:$source_path" >&2
      exit 1
    fi
  done < <(
    jq -r '.contracts | to_entries[] | select(.value | type == "object" and has("repository")) | [
      .value.repository,
      .value.sourcePath,
      .value.sourceBlob,
      (.value.deploymentRecordRevision // "" | if length == 0 then "-" else . end),
      .value.sourceRevision,
      .value.abiRevision
    ] | @tsv' "$manifest"
  )

  while read -r revision; do
    require_commit "$managed_oracle_repo" "$revision"
  done < <(
    jq -r '.sources | .managedOracle, .managedOracleDeploymentTooling, .ooReporterDeploymentTooling' "$manifest"
  )

  while read -r revision; do
    require_commit "$polymarket_repo" "$revision"
  done < <(
    jq -r '.sources | .polymarket, .polymarketDeploymentConfig' "$manifest"
  )
done

echo "FRO-111 source, ABI, deployment-record, and blob provenance verified"

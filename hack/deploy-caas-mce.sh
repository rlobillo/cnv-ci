#!/usr/bin/env bash
# Deploy the CAAS infrastructure (CAPI + CAPK + CAPOA providers +
# assisted-service) managed by MCE (multicluster-engine) — Phase 2
# deployment model.
#
# NOT IMPLEMENTED YET — placeholder. External blockers:
#   - CAPK is not registered as a standalone MCE component
#     (stolostron/backplane-operator PR pending)
#   - MCE bundle still ships placeholder digests for the CAPOA images
#     (Konflux release pipeline not wired yet)
#
# See epic CNV-93135 for tracking.

echo "ERROR: deploy-caas-mce.sh is not implemented yet (Phase 2, blocked upstream)" >&2
exit 1

#!/usr/bin/env bash
FIXTURE_NAME="sync-070-rbac-outside-distro"
source "$(dirname "$0")/common.sh"
init_repo "https://github.com/opendatahub-io/kserve.git"

# This fixture ships a trimmed .rules/rbac-isolation.md so the pointer path is
# exercised: safety-reviewer should read it from work_dir and apply it.
write_file .rules/rbac-isolation.md <<'MD'
# Midstream RBAC Isolation Rules

`controller-gen` scans `//+kubebuilder:rbac:` markers at the package level, regardless of build
tags. A `//go:build distro` tag does NOT prevent the marker from landing in the upstream
`config/rbac/role.yaml`. Only a dedicated `distro/` sub-package keeps midstream markers out.

## Violations - flag as blocking

1. **ODH RBAC markers outside `distro/`** - a file not under a `distro/` package path containing
   `//+kubebuilder:rbac:` markers for `*.opendatahub.io` or `*.openshift.io` groups. Move them to
   `pkg/<controller>/distro/controller_rbac_odh.go`.

   **Common mistake**: markers in a `*_odh.go` file that has `//go:build distro` but is not under
   `distro/`. The build tag does not help.

## Advisory - flag as non-blocking comment

3. **Istio RBAC markers outside `distro/`** - ask whether the permission is midstream-specific.
   Istio is used upstream too, so no action may be needed.

## Exemptions - do not flag

- Files under `distro/` containing only a package declaration and `//+kubebuilder:rbac:` markers.
  No build tag is intentional; controller-gen must scan them in all build configurations.

## Pre-existing technical debt - do not flag on unmodified files

- `pkg/controller/v1beta1/inferenceservice/controller.go` (`route.openshift.io`)
MD

write_file pkg/controller/v1alpha2/llmisvc/controller.go <<'GO'
package llmisvc

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

//+kubebuilder:rbac:groups=serving.kserve.io,resources=llminferenceservices,verbs=get;list;watch

type LLMISVCReconciler struct{}

func (r *LLMISVCReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	return ctrl.Result{}, nil
}
GO
commit "initial llmisvc controller"

write_file pkg/controller/v1alpha2/llmisvc/controller_odh.go <<'GO'
//go:build distro

package llmisvc

//+kubebuilder:rbac:groups=route.openshift.io,resources=routes,verbs=get;list;watch;create;update
//+kubebuilder:rbac:groups=infrastructure.opendatahub.io,resources=hardwareprofiles,verbs=get;list;watch
GO
commit "add ODH RBAC markers"

emit_repo

# KServe Review Rubric

Rules extracted from 1,219 review comments and 759 Jira bugs (156 Blocker/Critical)
across kserve/kserve and opendatahub-io/kserve.
Each rule has an ID, severity (MUST/SHOULD per RFC 2119), and applicability condition.

## API Design (API-*)

**API-010 | MUST | New or changed API types**
Typed APIs over annotations for first-class features. Annotations lock you into supporting them forever; typed fields
have schema validation and versioning.

**API-020 | MUST | Fields with enum validation**
Avoid strict enum validation when values may grow over time — new methods, new options. Use open enums or string with
documented values.

**API-030 | MUST | New spec fields**
Adding a status condition or spec field is non-breaking. Removing or renaming is breaking. Default to additive changes.

**API-040 | SHOULD | API naming**
Avoid redundant nesting: `speculativeDecoding.speculator` is repetitive. Flatten to `speculator.model`,
`speculator.numTokens`.

**API-050 | SHOULD | New CRD or API version**
Disaggregated serving requires independent scaling of prefill/decode — a top-level `replicas` doesn't work. Validate API
shape against all deployment topologies.

**API-060 | SHOULD | Configuration scope**
Start with top-level configuration that propagates to all managed components. Only add per-component overrides when a
concrete use case requires asymmetric config.

## Controller & Reconciler Patterns (CTL-*)

**CTL-010 | MUST | All reconciler code**
Exit early pattern. Reverse if-conditions to avoid deep nesting: check the negative/exit case first, return, then handle
the main logic at lower indentation.

**CTL-020 | MUST | Code accessing nested spec fields**
Guard against nil panics. Presets/baseRefs mean the "full spec" isn't available until config_merge runs. Fields like
`Router.Scheduler.Pool.Spec.ExtensionRef.Name` can be nil at any level. This also covers `+optional` fields populated by
a defaulting webhook: dereferencing them directly (`*field`) panics whenever the webhook is bypassed — envtest suites
that don't register it, direct API writes, or a webhook outage. Use `ptr.Deref` or an explicit nil guard; a default
marker is not a presence guarantee at the point the controller reads the field.

**CTL-030 | MUST | Event emission**
Never produce events on success or no-op. This causes high API server load and triggers client-side rate limiting.
Events are for errors and state transitions.

**CTL-040 | MUST | Sub-reconciler handling optional features**
Handle transitions: scheduler enabled→disabled, multi-node→single-node. Generic CRUD must handle `IsNotFound` AND
`meta.IsNoMatchError` (CRD not installed).

**CTL-050 | SHOULD | CRD availability checks**
Remove CRD gating from reconciler setup. Let the controller recover gracefully if CRDs are deployed later — watches
initialize on restart.

**CTL-060 | SHOULD | Repeated logic across sub-reconcilers**
Encapsulate repeated patterns (e.g., `ShouldForceStop`) into shared functions using interfaces like `metav1.Object`.
Don't duplicate branching logic in every reconciler.

**CTL-070 | SHOULD | Scaling/autoscaling reconcilers**
Structure actuator reconciliation for extensibility. Each actuator (HPA, KEDA) should have its own reconcile function
handling its own deletions independently.

**CTL-080 | SHOULD | Status condition updates**
Use non-terminal conditions for observability instead of event floods. Continuous states (scaling status) are
conditions, not events.

KServe's own status types embed knative `duckv1.Status` and use `apis.ConditionSet` (`llmInferenceServiceCondSet`,
`conditionSet` in `inference_service_status.go`). That machinery already handles `LastTransitionTime`, rollup into the
top-level `Ready`, and propagation of the failing dependent's reason and message — do **not** ask for those by hand,
and do **not** ask for a per-condition `observedGeneration`: knative's `apis.Condition` has no such field. What still
needs review:

- **New sub-conditions must be registered as dependents** in `apis.NewLivingConditionSet(...)`, otherwise they are set
  but never roll up into `Ready`, and a failing component leaves the resource reporting `Ready=True`. Adding a new
  `apis.ConditionType` constant without adding it to the condition set is the common form of this bug.
- **Distinct, stable, machine-readable `reason` values per failure mode** (`ModelNameMismatch` vs
  `ModelNameAmbiguous`). Knative takes the reason from the caller, so a shared reason across semantically different
  failures still defeats programmatic handling.
- **Reading conditions from foreign resources** (HTTPRoute, InferencePool, Gateway — these are `metav1.Condition` and
  *do* have `observedGeneration`) must apply the staleness check the surrounding code already establishes:
  `cond.ObservedGeneration < obj.Generation` means the condition describes an older spec. See
  `pkg/controller/v1alpha2/llmisvc/router_discovery.go` for the established pattern; new readers should match it.
- **Status writes only on semantic change**, so requeues and resyncs don't produce a write storm.

**CTL-090 | SHOULD | Reconciler structure**
Have a top-level `finalize(ctx, original)` method for cleanup to prevent the `else` branch from growing organically with
each new component.

**CTL-100 | MUST | Any reconciler output that flows into a Deployment/StatefulSet/LWS pod template**
Controller upgrades must never restart user workloads. The controller reconciles the desired state of Deployments,
StatefulSets, and LWS — any change to the reconciler's output that alters the pod template spec (annotations, labels,
command strings, env vars, volume mounts, security context) changes the pod template hash and triggers a rollout. This
is the #1 source of upgrade Blockers. Every reconciler change must be evaluated with the question: "If the controller
binary is upgraded but the user's CR hasn't changed, will existing pods restart?" Common triggers: (1) shell quoting
changes in modelcar/init container commands (RHOAIENG-71245), (2) annotation injection into pod templates (
RHOAIENG-59339), (3) config value changes that propagate to pod specs (RHOAIENG-59268), (4) security context changes (
readOnlyRootFilesystem, runAsNonRoot), (5) new labels/annotations added to pod metadata, (6) entrypoint script
formatting changes. (26+ Blockers across BUG-010, BUG-030, BUG-120)

**CTL-110 | MUST | Reconcile failures and retry results**
Return the error on reconciliation failure so controller-runtime applies its rate limiter. Do not replace a retryable
failure with `ctrl.Result{Requeue: true}, nil` or a timed successful result — that discards the error, loses the
failure signal from logs and metrics, and substitutes a flat retry interval for exponential backoff. Use `Requeue` only
when no error occurred but async work is still in progress, and `RequeueAfter` only for intentional wall-clock polling.
Note for reviewers: when the returned error is non-nil, controller-runtime **ignores** the `ctrl.Result` entirely, so
`return ctrl.Result{Requeue: true}, err` is redundant but harmless — it is not the violation. The violation is
swallowing the error.

**CTL-120 | SHOULD | Uncached or direct List operations over large collections**
Direct reads that bypass the informer cache — `APIReader`, a raw clientset, REST calls — over collections that can grow
unbounded must be paginated (`client.Limit` / the `client-go` pager) or replaced by an indexed cached read. An
unpaginated list of a large collection materializes the whole set in the controller and in the API server at once, and
concurrent unpaginated lists are a known cause of API server memory spikes. Do **not** flag a cache-backed
controller-runtime `List` for missing `Limit`: it is served from the informer cache, not the API server, and the cache
is the mitigation. Only raise the `limit` plus `resourceVersion=0` interaction (where the API server ignores pagination,
fixed in Kubernetes 1.34) when the project's supported cluster versions actually include the affected releases.

**CTL-130 | MUST | Workload-affecting derived resource identities**
Names and identities that flow into pod templates or managed workload resources must be order-independent. Deriving
them from a list index (`fmt.Sprintf("vol-%d", i)`) means reordering an unrelated list entry in the CR renames the
resource, which changes the pod template hash and restarts the workload for no reason. Sort by a stable semantic key
(name, UID) before processing, and derive the identity from that key rather than the position. Focused companion to
CTL-100: the test is "would renaming this derived resource trigger a rollout?"

**CTL-150 | MUST | Finalizer lifecycle**
A diff that adds a finalizer must guarantee its removal. On the deletion path, cleanup must be idempotent, must
tolerate the external resource already being absent (treat `IsNotFound` as success), and the finalizer must be removed
even when cleanup was a no-op. A finalizer whose removal is gated behind a cleanup step that can fail permanently wedges
object deletion and blocks namespace deletion, requiring manual operator recovery. Also flag the reverse: removing the
finalizer before cleanup completes, which leaks the external resource.

## Upstream Sync & ODH Overlay Discipline (SYNC-*)

**SYNC-010 | MUST | opendatahub-io/kserve changes**
Never patch upstream code with inline comments or modifications. Use ODH overlay to remove/patch what's needed.
Modifying base files creates merge conflict debt.

**SYNC-020 | MUST | opendatahub-io/kserve changes**
Prefer sync from upstream/master over cherry-picking individual commits. Cherry-picks diverge history; syncs keep
alignment.

**SYNC-030 | MUST | opendatahub-io/kserve PRs**
Target the correct branch. New features go to master. Release-specific fixes go to the release branch. When odh/master
is synced from upstream, retarget accordingly.

**SYNC-040 | SHOULD | opendatahub-io/kserve additions**
Adding code to upstream-synced files (e.g., code comments, logic) self-sabotages sync for no reason. Decouple
downstream-specific logic into separate files or overlays.

## Kustomize & Configuration (CFG-*)

**CFG-010 | MUST | Accelerator LLMInferenceServiceConfig**
Accelerator configs are overlays on top of base configs in `config/llmisvcconfig/`. They only override the image. Don't
re-set security context, runAsNonRoot, etc. — the base already defines hardening.

**CFG-020 | MUST | Image references in overlays**
Images go in `params.env` and get injected via kustomization. New images need a companion PR in the operator for
injection (see `opendatahub-operator` kserve_support.go).

**CFG-030 | MUST | LLMInferenceServiceConfig changes**
Well-known injected configs live in `config/llmisvcconfig/`. User-provided configs should only override the minimum
delta. Trim configs to the minimum — don't repeat values matching injected defaults.

**CFG-040 | SHOULD | Config versioning**
Embed feature logic in llmisvcconfig base configs where possible. This gives prefix-based stable versioning for free and
prevents container restarts on upgrade.

## Security & TLS (SEC-*)

**SEC-010 | MUST | New sidecar or service**
Include the new service in TLS SANs and IPs of certificates. Check existing workload_tls_self_signed.go for the SAN/IP
builder pattern.

**SEC-020 | MUST | New sidecar or service**
Pass TLS flags and volume mounts consistently. Match the pattern in `config-llm-template.yaml` for TLS args, cert paths,
and volume mounts.

**SEC-030 | MUST | Any networking code**
Never use `InsecureSkipVerify`. Gate on certificate rotation support. Check if the target component supports automatic
cert rotation before deciding the TLS strategy.

**SEC-040 | MUST | RBAC changes**
Use ClusterRole for cluster-scoped resources (TokenReview, SubjectAccessReview). Use namespaced Role for
namespace-scoped resources.

**SEC-050 | SHOULD | Security context**
Base configs define runAsNonRoot and security context. Don't re-set in overlays. Check that new containers/pods inherit
the base security context. On OpenShift, never hardcode a numeric `runAsUser` in a controller-managed workload
template: SCC assigns each namespace a UID range, and a fixed UID outside that range makes the pod unschedulable. Use
`runAsNonRoot: true` and let the platform assign the UID. Generic hardening advice is not automatically safe here —
`readOnlyRootFilesystem: true` breaks CDI-based GPU injection and OCI modelcar serving, so see BUG-030 before
recommending it.

**SEC-060 | MUST | AuthPolicy or authorization rules with multiple paths**
Fail closed on authorization path mismatch. When multiple authorization rules exist (e.g., model-level SAR vs
instance-level SAR), a request that carries credentials or headers for a specific auth path (e.g., model routing header)
MUST be explicitly denied if it fails that path's authorization — it must not fall through to a weaker auth path or to
authn-only. The routing signal (header, path prefix) and the authorization check must always agree on which resource is
being accessed. Cross-path fallthrough enables cross-tenant escalation: a request routed to tenant-B's backend via
header but authorized against tenant-A's namespace via path segments. (Discovered
in https://github.com/opendatahub-io/odh-model-controller/pull/881)

**SEC-065 | MUST | AuthPolicy or HTTPRoute changes for LLMInferenceService**
AuthPolicy rules and HTTPRoute paths are a cross-repo security contract. Every routable path/header match must have a
corresponding authorization rule — gaps create unauthenticated access or cross-tenant escalation.
When reviewing **kserve PRs** that change `config/llmisvcconfig/config-llm-router-route.yaml` (new path prefixes, header
matches, catch-all patterns): cross-reference the AuthPolicy template in
odh-model-controller (https://raw.githubusercontent.com/opendatahub-io/odh-model-controller/refs/heads/incubating/internal/controller/resources/template/authpolicy_llm_isvc_userdefined.yaml)
to verify all new routes are covered by auth rules.
When reviewing **odh-model-controller PRs** that change AuthPolicy templates: cross-reference the HTTPRoute template in
kserve (https://raw.githubusercontent.com/kserve/kserve/refs/heads/master/config/llmisvcconfig/config-llm-router-route.yaml)
to verify all routable paths are still authorized or explicitly denied.
(Discovered in https://github.com/opendatahub-io/odh-model-controller/pull/881)

**SEC-070 | MUST | CEL expressions in AuthPolicy templates**
Validate all interpolated values in CEL expressions against injection. Template variables (e.g.,
`{{.ModelRoutingHeader}}`) interpolated into CEL strings must be validated with a strict allowlist before rendering.
Verify the allowlist blocks all CEL-significant characters: quotes, parentheses, backslashes, pipes, ampersands. Add
unit tests covering edge cases for the validation function.

**SEC-075 | MUST | New listeners or outbound connections**
New servers and outbound connections must use TLS/HTTPS. Flag plaintext HTTP listeners, gRPC servers/dials without
transport credentials, and outbound clients that do not enforce TLS. Exception: intra-pod communication over localhost
(`127.0.0.1`, `localhost`, `::1`) between containers in the same pod may use plaintext, because it never crosses the
pod network boundary. A listener bound to `0.0.0.0` or a named service address is not intra-pod, even if today's only
caller is local.

**SEC-080 | MUST | RBAC rules or kubebuilder RBAC markers**
Flag wildcard verbs, resources, or API groups (`"*"`) and grants of `escalate`, `bind`, or `impersonate` unless the diff
supplies a specific, reviewable justification — these let the holder grant themselves any permission, which makes the
rest of the RBAC surface moot. Access to `secrets`, `nodes/proxy`, `pods/exec`, `pods/attach`, and
`certificatesigningrequests/approval` is dangerous but often legitimate; require least-privilege scoping (narrow verbs,
`resourceNames` where the set is fixed, namespaced Role instead of ClusterRole where the resource is namespaced) rather
than treating it as an automatic violation. Cross-check `//+kubebuilder:rbac` markers against the generated role and
against the client operations the reconciler actually performs: a marker granting more than the code uses is the
common form of drift. Complements BUG-050 (missing RBAC for new watches) — establish actual usage from the code before
proposing a narrower grant, so a least-privilege suggestion does not break a watch.

**SEC-090 | SHOULD | New workloads or pod templates**
A new workload that does not call the Kubernetes API should run under a dedicated ServiceAccount with
`automountServiceAccountToken: false`, so a compromised container has no cluster credential to steal. KServe already
does this in `config/llmisvcconfig/config-llm-tokenizer.yaml`; match that pattern. Before filing, check both the pod
spec and the ServiceAccount — the setting is inherited, so a pod under an SA that already disables automount is
compliant. Not a finding for workloads that genuinely need API access or use projected/bound tokens.
**Applies to newly added workloads only.** Adding `automountServiceAccountToken: false` to an existing
controller-managed pod template changes the pod template hash and forces a rollout on upgrade — that is a CTL-100 /
BUG-010 violation, and the hardening is not worth an upgrade Blocker. For existing templates, raise it as a note, not a
required change.

**SEC-100 | MUST | GitHub Actions workflow changes**
Untrusted-input handling in CI. Flag: (1) direct interpolation of attacker-controlled event data
(`github.event.pull_request.title|body|head.ref`, issue comments) into a `run:` block, which is shell injection — pass
it through `env:` and reference `"$VAR"` instead; (2) `pull_request_target` workflows that check out and execute PR-head
code, which runs untrusted code with a privileged token and repository secrets; (3) third-party actions referenced by
tag or branch rather than a full commit SHA; (4) broader `permissions:` than the job needs, especially write scopes on
jobs that execute untrusted code.
`pull_request_target` is not itself a violation — KServe uses it correctly in `auto-assign-reviewers.yml` and
`pr-style-check.yml`, which pin actions by SHA, check out `ref: master` rather than PR head, pass event data via `env:`,
and scope permissions per job. Flag the unsafe combination, not the trigger.

**SEC-110 | MUST | Logging, error wrapping, or event/condition messages**
Secret material must not reach logs, error strings, Events, or status conditions. Values from `Secret.Data` /
`StringData`, decoded tokens, passwords, and API keys are all permanently exposed once written to a log aggregator, and
KServe handles `HF_TOKEN`, storage credentials, and imagePullSecrets throughout the storage pipeline (see BUG-120).
Logging an object that embeds secret values counts.
**Not findings** — these are references, not secret material: Secret names and namespaces, key *names* and field
selectors (`modelInfo.Storage.StorageKey` is the name of a key inside the storage-config Secret, not the credential),
ServiceAccount names, and object references. Only flag a value that is itself the secret.

## Testing (TST-*)

**TST-010 | MUST | Bug fixes**
Add regression tests. Every fix needs a test that would have caught the bug.

**TST-020 | MUST | Test assertions**
Tests must fail on error, not log warnings on green checks. If a check can't be asserted reliably, document why with
`pytest.mark.xfail`, not a try/except that swallows the failure.

**TST-030 | SHOULD | E2E tests**
Log actions with timestamps for debugging. Collect related objects (pods, pod logs, deployments, InferencePools,
HTTPRoutes) using part-of/component labels — status alone doesn't describe the full picture.

**TST-040 | SHOULD | API version changes**
Augment the test matrix to cover both old and new API versions end-to-end. Don't assume one version — test the migration
path.

**TST-050 | SHOULD | Test skipping**
Guard against skipping critical tests silently. If a prerequisite (RHCL, CRD) is expected to be installed, don't skip —
fail loudly so regressions are noticed.

**TST-060 | SHOULD | Integration tests**
Add integration tests in `*_int_test.go` for controller logic. Smoke E2E tests for new features when resource
requirements allow.

## Naming & Resource Conventions (NAM-*)

**NAM-010 | MUST | New Kubernetes resources**
Prefix with `kserve-` to avoid clashes with other resources in shared namespaces (e.g., `kserve-llm-isvc-vllm-engine`,
not `llm-vllm-engine`).

**NAM-020 | MUST | Webhook names**
Keep webhook names stable across versions. Changing webhook names creates "ghost" webhooks during upgrades (old name
persists without match policy, new name gets created).

**NAM-030 | SHOULD | Naming specificity**
Be specific: `llm-isvc` not just `llm`. Consistency with relabelings and other resources in the namespace.

## Migration & Upgrade Safety (MIG-*)

**MIG-010 | MUST | Changes to propagated labels/annotations**
Top-level `.metadata` label/annotation propagation causes unintended restarts/rollouts when unrelated labels change.
Keep propagation scoped to explicit workload-level labels.

**MIG-020 | MUST | Protocol or API version changes**
Can't assume all services run the latest version. Check the component version (similar to scheduler migration logic) and
fall back to the previous version if the new one can't be determined.

**MIG-030 | MUST | InferencePool or resource migration**
Test migration with actual gateway/proxy versions. An InferencePool migrated to v1 will break if the Istio version
doesn't support it.

**MIG-040 | SHOULD | Feature reconciliation**
Embed feature logic in llmisvcconfig (versioned via prefix) rather than controller code to prevent restarts on upgrade.
Controller changes require pod restarts; config changes don't.

**MIG-050 | MUST | Changes to Go template functions in ReplaceVariables (config_merge.go)**
Template functions registered in `ReplaceVariables` are a shipped API contract. Previously released llmisvcconfig YAML
files reference these functions by name — removing or renaming a function breaks all existing configs on upgrade.
Functions can only be added, never removed or renamed. If a function's behavior needs to change, the new behavior must
be backward-compatible or a new function must be added alongside the old one. The same applies to function signatures —
changing parameter types or count breaks existing template invocations. (kserve/kserve#5717)

**MIG-060 | MUST | Changes to llmisvcconfig template variables or structure**
LLMInferenceServiceConfig templates are versioned by prefix and shipped with releases. Any change to the template
variable names, Go template syntax, or expected input structure breaks previously shipped configs on upgrade. New
variables can be added (templates ignore undefined variables with `{{if}}`), but existing variables cannot be removed or
change type. Test template rendering against configs from the previous release.

## Cross-Repo Coordination (XREPO-*)

**XREPO-010 | MUST | New images or config changes**
Flag when a PR needs companion changes in other repos (operator, odh-model-controller, kserve-module). Missing
coordination blocks deployment.

**XREPO-020 | SHOULD | Module integration**
New overlays or resources must be integrated with the operator module (kserve-module) to be applied. Resources in
overlays that aren't wired into the module won't be deployed.

## Bug-Prone Patterns (BUG-*)

Rules derived from 342 real bugs (93 Blocker, 63 Critical, 75 Major, 65 Normal).

**BUG-010 | MUST | Any change to pod template, annotations, labels, or config**
Upgrade restart risk. See CTL-100 for the core rule. This bug pattern captures the downstream symptoms: unnecessary
rollouts during upgrades caused by annotation injection, shell quoting changes, config value drift, or security context
modifications. The test is: "Does `kubectl diff` on a Deployment managed by this controller show changes when only the
controller binary was upgraded?" (9 Blockers: RHOAIENG-59339, RHOAIENG-59268, RHOAIENG-71245)

**BUG-020 | MUST | Image references in params.env, kustomization, or llmisvcconfig**
Wrong image tag. Placeholder images (`controller:latest`), missing kustomize replacements, and version-mismatched image
tags are a top source of Blockers. Every image reference must have a corresponding kustomize replacement entry AND
operator injection. (10 bugs: RHOAIENG-69531, RHOAIENG-55878, RHOAIENG-75982)

**BUG-030 | MUST | Security context changes (readOnlyRootFilesystem, runAsNonRoot, seccomp)**
Security context breaks GPU/device injection. `readOnlyRootFilesystem: true` breaks CDI-based GPU injection (
nvidia-cdi-hook) and OCI modelcar serving. `runAsNonRoot` breaks procfs symlinks and some xKS deployments. Validate
against all accelerator types and deployment targets. (5 Blockers: RHOAIENG-75488, RHOAIENG-71150, RHOAIENG-56701)

**BUG-040 | MUST | API version bumps, CRD changes, or controller upgrades**
Missing migration logic. Version upgrades without migration logic cause CrashLoopBackOff, deadlocks, and Ready=False.
Every version change needs: migration path, conversion webhook if needed, fallback to previous version. (11 bugs, 7
Blockers: RHOAIENG-58364, RHOAIENG-54344, RHOAIENG-76305)

**BUG-050 | MUST | New CRD watches, new resources, or new API group access**
Missing RBAC. New watches on resources (InferenceModelRewrites, ClusterStorageContainers) need corresponding RBAC
entries in the distro ClusterRole. Aggregated roles need labels for user-facing CRDs. (26 bugs: RHOAIENG-56779,
RHOAIENG-54987, RHOAIENG-60685)

**BUG-060 | MUST | New binaries, sidecars, or Go dependencies on FIPS/restricted clusters**
TLS/FIPS compatibility. New binaries must pass FIPS selftest. Go binaries need FIPS-compliant crypto. Sidecars need
correct OpenSSL initialization. CPU-specific instructions (SIGILL on AMD EPYC). Flag mismatches (`-enable-cert-reload`
not defined). (47 bugs: RHOAIENG-58354, RHOAIENG-58765, INFERENG-6224)

**BUG-070 | MUST | ServiceMonitor, PodMonitor, or metrics port changes**
Monitoring breakage. Hardcoded `matchNamespace` fields, missing NetworkPolicy ports for Prometheus scraping, wrong label
selectors on monitors. Every new metrics endpoint needs: ServiceMonitor/PodMonitor, NetworkPolicy egress rule, and
dashboard integration. (45 bugs: RHOAIENG-59920, INFERENG-5614, INFERENG-6140)

**BUG-080 | SHOULD | Hardcoded timeouts, ports, namespaces, or resource names**
Hardcoded values break at scale or in non-standard environments. Hardcoded startupProbe timeouts fail for large models.
Hardcoded namespace selectors fail in multi-tenant. Hardcoded secrets are security risks. Make values configurable or
derive from context. (8 bugs: RHOAIENG-75793, INFERENG-5614, RHOAIENG-69776)

**BUG-090 | SHOULD | NetworkPolicy changes or new service ports**
NetworkPolicy blocks. New service ports (metrics, webhooks, sidecars) need corresponding NetworkPolicy rules. Prometheus
scraping is frequently blocked by namespace-scoped NetworkPolicies. (8 bugs: RHOAIENG-58209, INFERENG-7687)

**BUG-100 | SHOULD | Kustomize replacement targets or overlay field paths**
Kustomize replacement failures. Targeting non-existent fields (`spec.namespaceSelector.matchNames.0`) breaks the entire
kustomize build. Test replacement paths against the actual manifests. Missing replacements leave placeholder values in
production. (5 bugs: RHOAIENG-56264, RHOAIENG-55878)

**BUG-110 | SHOULD | Multi-node, P/D, or LeaderWorkerSet changes**
Multi-node edge cases. Status conditions stuck at Unknown despite pods running, entrypoint scripts that only consider
the first NIC/HCA, metrics over-counted when LWS replicas have multiple metric-emitting pods. Test with actual
multi-node topologies. (21 bugs: RHOAIENG-70416, INFERENG-6968, INFERENG-8439)

**BUG-120 | MUST | Storage initializer, modelcar container, init container injection, or storageUri handling**
Storage/model injection pipeline failures. Changes to `pkg/utils/storage.go`, modelcar command generation, init
container construction, or webhook storageUri mutation. Distinct from CTL-100 (restart-on-upgrade), this covers
storage-specific breakage: (1) argument list too long — large model lists exceed execve limits (RHOAIENG-30376,
Blocker); (2) HF_TOKEN and credentials not propagated to init containers (RHOAIENG-69344); (3) mutating webhook strips
storageUri when imagePullSecrets secret is deleted (RHOAIENG-61105); (4) FIPS check-payload failure in
storage-initializer binary (RHOAIENG-60931, Blocker); (5) multi-arch build failures for ppc64le/s390x (RHOAIENG-50492,
RHOAIENG-50322, Blockers); (6) versioned model path handling — can't download specific model versions (
RHOAIENG-34931); (7) ClusterStorageContainer manifest doesn't support multi-model download (RHOAIENG-57629); (8)
downloads entire HF repo instead of required files (RHOAIENG-69346). For pod template hash stability of shell quoting
and command strings, see CTL-100. (26 bugs, 9 Blockers)

## Code Quality (CODE-*)

**CODE-010 | SHOULD | Complex init scripts**
Prefer readability over DRY for init/entrypoint scripts. Overly templated bash scripts (gotemplate in bash) are hard to
debug. Push back if readability suffers.

**CODE-020 | SHOULD | Owner references**
Don't assume the first owner reference is "ours". Loop through owner refs and check by kind/name. Guard array access
with length checks.

**CODE-030 | SHOULD | Sidecar configuration**
Use the llmisvcconfig mechanism (well-known configs with prefix versioning) for sidecar injection rather than arbitrary
injection. This gives consistent UX and prevents restart-on-upgrade.

**CODE-040 | SHOULD | Default configuration**
Modify default configurations in the known location rather than injecting overrides arbitrarily. If there will ever be a
better alternative, arbitrary injection locks you in with no override path.

**CODE-050 | SHOULD | Comparing resources whose fields are partially owned by others**
When deciding whether an owned resource needs an update, use a subset comparison (`equality.Semantic.DeepDerivative`)
for the fields the controller actually owns. Exact comparison (`DeepEqual`, `maps.Equal`) against a resource that
webhooks, other controllers, or users also mutate produces a permanent update loop: the controller reverts their
fields, they re-add them, and reconciliation never converges. Use exact comparison only where a removal is semantically
meaningful (for example backendRefs dropped because a group member was deleted). For labels and annotations, combine a
subset check with an explicit stale check for the specific controller-managed keys, so removals of those keys are still
detected without fighting user-added ones. Establish who owns the compared fields before filing a finding.

**CODE-060 | SHOULD | Inspecting `corev1.EnvVar` intent**
`EnvVar.Value` is empty when the variable is sourced via `ValueFrom` (`configMapKeyRef`, `secretKeyRef`,
`fieldRef`). Code that detects user intent by inspecting only `.Value` — "skip injection if the user already set flag
X" — silently takes the wrong branch for any user who sourced that variable from a ConfigMap or Secret. Handle
`ValueFrom` explicitly, or use a dedicated API field or annotation for the escape hatch instead of inferring intent
from env values. Not a finding when the code intentionally accepts literal values only and validates that contract.

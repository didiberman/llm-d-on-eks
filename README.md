# llm-d on EKS — request-autoscaled LLM inference you can afford to practice on

A learning project: [llm-d](https://llm-d.ai) **v1.0.0** serving an open-weights model on
EKS, autoscaling on **inference queue depth** (not CPU), with GPU nodes that
scale to zero when idle. Terraform, start to finish.

The design goal is not "production grade." It is **a 3-hour practice session for
well under a dollar**, with hard guardrails so a forgotten GPU can't bill you for
a week.

> Status: scaffolding. See [Build order](#build-order) for what works today.

---

## The cost model, measured

All prices are `us-east-1` **spot**, sampled 2026-10-28 via `describe-spot-price-history`.
Re-measure with `make prices` — they move.

| Tier | What runs | GPU | Cost/hr | What it proves |
|------|-----------|-----|---------|----------------|
| **T0** `make sim-local` | kind on your laptop + `llm-d-inference-sim` | no | **$0.00** | router, EPP, KEDA ScaledObject, scaling behaviour, every line of YAML |
| **T1** `make sim-eks` | EKS + `llm-d-inference-sim` on `t3.large` | no | **~$0.15** | real EKS, Istio Gateway, NLB, IRSA, Karpenter, autoscaling end-to-end |
| **T2** `make gpu` | EKS + `g6.xlarge` spot + vLLM 0.30 | yes | **~$0.60** | real tokens, real throughput, real scale-out under load |

A realistic session — 2h at T0, 30m at T1, 30m at T2 — lands around **$0.40**.

### Why there is no CPU-vLLM tier

llm-d ships a CPU model server at `guides/optimized-baseline/modelserver/cpu/vllm`.
It is a **cost trap for this use case** and deliberately not used here:

| | vCPU | Spot cost |
|---|---|---|
| Shipped CPU overlay: `cpu: "64"` × 2 replicas | 128 | **$1.37/hr** |
| `g6.xlarge` GPU | 4 | **$0.47/hr** |

Real CPU inference costs ~3× the GPU and needs 4× the default 32-vCPU account
quota. For everything short of real token throughput,
[`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim) is strictly
better: it speaks the vLLM OpenAI API and emits real vLLM Prometheus metrics, so
**KEDA scales against it exactly as it would against the real thing** — for
$0.022/hr on a `t3.large`, or free on kind.

Spend GPU money on the one thing only a GPU proves: tokens per second.

### Where the money actually leaks

The GPU is not the problem. These are:

| Leak | Naive cost | Here |
|------|-----------|------|
| **NAT Gateway** (3 AZ × $0.045/hr) | $0.135/hr | **$0** — no NAT; public subnets + VPC endpoints |
| **NAT data processing** — a ~10GB vLLM image and 3–15GB of weights, *per pod start* | ~$0.045/GB | **$0** |
| EKS control plane, left running | $73/mo | `make nuke` → $0; nightly reaper enforces it |
| Forgotten GPU node | ~$340/mo | reaper + budget alarm |

Dropping NAT Gateway is the single largest line-item win, and it is why this repo
does **not** use the stock `terraform-aws-modules/vpc` defaults.

---

## Architecture

```
                    Internet
                       │
              NLB (Istio Gateway)
                       │
         ┌─────────────▼─────────────┐
         │   llm-d Router v1.0.0     │   standalone mode
         │   + Endpoint Picker (EPP) │   prefix-cache & load aware routing
         └─────────────┬─────────────┘
                       │
         ┌─────────────▼─────────────┐
         │  vLLM 0.30 model servers  │  ← KEDA scales replicas on
         │  (or llm-d-inference-sim) │    EPP queue-depth metric
         └─────────────┬─────────────┘
                       │
         ┌─────────────▼─────────────┐
         │ Karpenter NodePool        │  ← provisions g6/g5 spot;
         │ consolidation → 0 nodes   │    terminates when empty
         └───────────────────────────┘
```

**Two independent scaling layers** — conflating them is the usual source of confusion:

- **Routing** — llm-d's EPP picks *which* replica serves a request, using
  prefix-cache-aware and load-aware scoring. Does not change replica count.
- **Scaling** — KEDA drives *how many* replicas exist from EPP's queue-depth
  metric. Queue depth, **not** GPU utilisation: a saturated GPU and a comfortable
  GPU both read ~100%, so utilisation cannot tell you to scale.

Then Karpenter closes the loop — replicas at 0 means nodes are empty, and
`consolidationPolicy: WhenEmptyOrUnderutilized` reclaims them in about a minute.
Idle cost falls to the $0.10/hr control plane with the cluster still live.

Cold start 0→1 is roughly **2–5 minutes** (node provision ~60–90s, GPU image
pull, weight load, CUDA graph capture). Driving that number down is the most
interesting engineering here; measurements go in [`docs/COSTS.md`](docs/COSTS.md).

### Pinned versions (llm-d v1.0.0 aligned)

| Component | Version |
|-----------|---------|
| llm-d router (`oci://ghcr.io/llm-d/charts/llm-d-router-standalone`) | `v1.0.0` |
| `llm-d-router-endpoint-picker` | `v1.0.0` |
| `llm-d-inference-sim` | `v1.0.0` |
| Gateway API CRDs | `v1.6.2` |
| Gateway API Inference Extension (GAIE) CRDs | `v1.6.2` |
| Istio (gateway provider) | `1.29.4` |
| vLLM base image | `docker.io/vllm/vllm-openai:v0.30.0` |
| LeaderWorkerSet | `1.0.0` |

llm-d v1.0 **removed kgateway**; Istio is the best-tested provider. Istio's
Gateway API implementation provisions a Service of type LoadBalancer, which on
EKS is an **NLB** — not an ALB. Same $0.0225/hr, and a better fit for streaming
token responses.

---

## Layout

```
terraform/
  00-bootstrap/   S3 state bucket + DynamoDB lock       run once,  ~$0
  10-cluster/     VPC (no NAT) + EKS + Karpenter + Istio ~16 min,   $0.10/hr
  20-inference/   llm-d router + modelserver + KEDA      ~4 min,    GPU cost
manifests/
  sim/            llm-d-inference-sim overlay (T0/T1)
  gpu/            small-model GPU overlay (T2)
local/            kind cluster config for T0
loadgen/          k6 script + in-cluster Job
```

The 10/20 split exists because **you will iterate on 20 about thirty times and on
10 maybe twice**. One state file means every vLLM config typo costs a 16-minute
cluster rebuild.

## Commands

```
make sim-local   # T0: kind + simulator, $0
make sim-eks     # T1: cluster + simulator on EKS
make gpu         # T2: cluster + real vLLM on g6.xlarge spot
make load        # fire k6, watch replicas climb
make down        # destroy layer 20 → GPU gone, cluster warm ($0.10/hr)
make nuke        # destroy everything → $0.00/hr
make cost        # actual spend to date, from Cost Explorer
make prices      # re-measure spot prices
```

Default end-of-session habit is `make nuke`. `make down` is for coming back in an hour.

## Guardrails

- **Nightly reaper** — scheduled GitHub Actions workflow destroys the GPU layer
  every night via OIDC, regardless of state. The highest-value protection here.
- **AWS Budget + SNS email** at a threshold you set in `terraform.tfvars`.
- **Mandatory tagging** — every resource carries `Project=llm-d-on-eks`, which is
  what makes `make cost` able to tell you the truth.

## Prerequisites

- Terraform ≥ 1.9, `kubectl`, `helm` ≥ 3.10, `aws` CLI v2, `kind` (T0 only)
- An AWS account, and for T2 only: **G/VT spot quota ≥ 8 vCPU** in your region.
  New accounts default to **0** and the quota is denominated in **vCPUs, not
  instances** — `g6.xlarge` is 4 vCPU, so a limit of 3 launches nothing. Request
  via Service Quotas codes `L-3819A6DF` (spot) and `L-DB2E81BA` (on-demand).
- A HuggingFace token in `TF_VAR_hf_token`. Required even for ungated models —
  the llm-d charts expect the `llm-d-hf-token` secret to exist.

## Build order

T0 and T1 need no GPU quota, so they come first.

- [ ] `00-bootstrap` — remote state
- [ ] `local/` + `manifests/sim/` — T0, $0
- [ ] `10-cluster` — VPC/EKS/Karpenter/Istio
- [ ] `20-inference` — router + KEDA on queue depth
- [ ] `manifests/gpu/` — T2 small-model overlay
- [ ] reaper + budget + `make cost`
- [ ] `docs/COSTS.md` — measured cold-start and $/1M-token numbers

## Honest caveats

- **llm-d's real wins need scale.** Prefix-cache-aware routing and
  prefill/decode disaggregation pay off across many GPUs. On one `g6.xlarge`
  serving a small model, llm-d is net overhead — you're exercising the control
  plane, not demonstrating a speedup. That's a fine reason to build it for
  learning, but don't expect flattering benchmarks.
- **Public endpoint, no auth.** The NLB is internet-facing and unauthenticated by
  default. Set `allowed_cidrs` in `terraform.tfvars` to your own IP.
- **Spot interruptions are real.** Nodes can vanish with a 2-minute warning.
  That's a feature for a learning project — it's how you find out whether your
  deployment actually tolerates it.

## License

Apache-2.0

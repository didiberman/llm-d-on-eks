# Cost model

Every number here was measured, not estimated. Re-measure with `make prices`.

- **Region:** `us-east-1`
- **Sampled:** 2026-10-28, 3-hour spot price window
- **Method:** `aws ec2 describe-spot-price-history`, minimum across AZs

## Measured spot prices

| Instance | vCPU | GPU | Spot $/hr | Role |
|----------|------|-----|-----------|------|
| `t3.large` | 2 | — | **0.0223** | T1 simulator host |
| `m7i.xlarge` | 4 | — | 0.0866 | T1 alternative |
| `g4dn.xlarge` | 4 | T4 16GB | 0.2849 | cheapest GPU; **no bf16** |
| `g6.xlarge` | 4 | L4 24GB | **0.4709** | T2 default |
| `g5.xlarge` | 4 | A10G 24GB | 0.4751 | T2 alternative |
| `m7i.16xlarge` | 64 | — | 0.6855 | what the shipped CPU overlay demands, ×2 |

Fixed costs on top: **EKS control plane $0.10/hr** per cluster, **NLB ~$0.0225/hr**
plus LCUs. This project runs **no NAT Gateway** — see below.

### GPU choice

`g6.xlarge` (L4, 24GB) over `g4dn.xlarge` (T4, 16GB) despite costing $0.19/hr more.
The T4 lacks bf16 and FlashAttention-2 support, so vLLM falls back to slower fp16
kernels — you end up paying less per hour for materially worse tokens/sec, and the
24GB on the L4 leaves room to try a 7B model. `g5.xlarge` (A10G) is within noise of
`g6` on price; either is fine.

## Per-tier hourly cost

| Tier | Components | $/hr |
|------|-----------|------|
| **T0** local | kind on your laptop | **0.00** |
| **T1** sim on EKS | EKS 0.10 + 2× `t3.large` 0.045 + NLB 0.0225 | **~0.17** |
| **T2** GPU | EKS 0.10 + `g6.xlarge` 0.471 + NLB 0.0225 + EBS ~0.01 | **~0.60** |
| idle, cluster up | EKS control plane only, nodes consolidated to zero | **0.10** |
| idle, nuked | nothing | **0.00** |

A 3-hour session spent 2h/30m/30m across T0/T1/T2 ≈ **$0.39**.

## Why no CPU-vLLM tier

llm-d ships `guides/optimized-baseline/modelserver/cpu/vllm`. Its
`patch-vllm.yaml` requests `cpu: "64"`, `memory: 64Gi`, `replicas: 2`, serving
gated `meta-llama/Llama-3.2-3B-Instruct`.

| | vCPU | Spot $/hr |
|---|------|-----------|
| 2 × `m7i.16xlarge` (what that overlay needs) | **128** | **1.371** |
| 1 × `g6.xlarge` | 4 | **0.471** |

Three times the cost of the GPU, and 128 vCPU is **four times** the default
32-vCPU on-demand standard-instance quota on a new account — so it cannot even
launch without a second quota increase.

Shrinking it (1 replica, 4 vCPU, a 1.5B model) is possible but yields single-digit
tokens/sec, which demonstrates nothing you couldn't learn for free. The simulator
is the better trade: it speaks the vLLM OpenAI API and emits genuine vLLM
Prometheus metrics, so the KEDA ScaledObject and all scaling behaviour are
exercised identically — at $0.00 on kind.

**Conclusion: for this workload the GPU is the cheap path.** Reserve GPU spend for
the only question a GPU uniquely answers — tokens per second.

## Where the money actually leaks

Ranked by what they'd cost over a month if left alone:

| Leak | Idle cost | Mitigation |
|------|-----------|------------|
| Forgotten `g6.xlarge` spot | ~$340/mo | nightly reaper + budget alarm |
| EKS control plane | $73/mo | `make nuke`; reaper |
| **NAT Gateway** × 3 AZ | **$98/mo** | **none created** — public subnets + VPC endpoints |
| NLB | $16/mo | destroyed with layer 20 |
| NAT data processing | $0.045/GB | n/a — no NAT |

### The NAT Gateway trap

`terraform-aws-modules/vpc` with `enable_nat_gateway = true` and
`one_nat_gateway_per_az = true` creates three NAT Gateways at $0.045/hr each.
Worse, it bills **$0.045 per GB processed**, and an LLM workload pulls a ~10GB
vLLM image plus 3–15GB of model weights **on every cold pod start**. Ten cold
starts of a 7B model is ~$7 in data processing alone — more than the GPU time
that motivated it.

This repo puts nodes in **public subnets with public IPs** and adds VPC endpoints
for ECR and S3. HuggingFace ingress is free. Verify none ever appear:

```sh
make whats-running   # the NAT gateway line must stay empty
```

## To be measured

Numbers that need a real run; this file gets updated as they land.

- [ ] Cold start 0→1: node provision → pod Ready → first token
- [ ] Warm scale 1→2 under load, and KEDA reaction lag from queue depth
- [ ] Tokens/sec on `g6.xlarge` for the chosen model
- [ ] $/1M tokens at steady state
- [ ] Spot interruption frequency over a session
- [ ] Actual `make cost` total for a full practice session

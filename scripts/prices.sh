#!/usr/bin/env bash
# Re-measure spot prices for the instance types this project uses.
#
# Every cost figure in README.md and docs/COSTS.md came from this script. Spot
# prices move; re-run it rather than trusting the committed numbers.
set -euo pipefail

REGION="${1:-us-east-1}"

# GPU candidates for T2, plus the cheap CPU node T1 runs the simulator on, plus
# the 64-vCPU class the shipped llm-d CPU overlay would demand (kept visible
# because it is the whole reason this project does not use that overlay).
TYPES=(
  t3.large      # T1 simulator host
  m7i.xlarge    # T1 alternative
  g4dn.xlarge   # T2 — T4 16GB, no bf16
  g5.xlarge     # T2 — A10G 24GB
  g6.xlarge     # T2 — L4 24GB, recommended
  m7i.16xlarge  # what the shipped CPU overlay needs, ×2
)

START=$(date -u -v-3H +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%S)

printf '%-16s %-6s %-12s %s\n' "INSTANCE" "vCPU" "SPOT/hr" "GPU"
printf '%-16s %-6s %-12s %s\n' "----------------" "------" "------------" "---"

for it in "${TYPES[@]}"; do
  spot=$(aws ec2 describe-spot-price-history \
    --region "$REGION" --instance-types "$it" \
    --product-descriptions "Linux/UNIX" --start-time "$START" \
    --query 'min_by(SpotPriceHistory,&to_number(SpotPrice)).SpotPrice' \
    --output text 2>/dev/null || echo "n/a")

  read -r vcpu gpu <<<"$(aws ec2 describe-instance-types \
    --region "$REGION" --instance-types "$it" \
    --query 'InstanceTypes[0].[VCpuInfo.DefaultVCpus,GpuInfo.Gpus[0].Name]' \
    --output text 2>/dev/null || echo "? ?")"

  printf '%-16s %-6s %-12s %s\n' "$it" "$vcpu" "\$${spot}" "${gpu:-none}"
done

echo
echo "EKS control plane is a flat \$0.10/hr per cluster on top of the above."
echo "NLB is ~\$0.0225/hr + LCUs. This project runs no NAT Gateway (\$0.045/hr each)."

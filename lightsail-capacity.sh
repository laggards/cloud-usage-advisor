#!/usr/bin/env bash
set -euo pipefail

REGION="ap-northeast-1"
BUFFER="0.10"
MONTHLY_TRANSFER_GB="2000"
MONTHLY_TRANSFER_SET="false"
AS_OF="$(date -u +%F)"
MOCK_USED_GB=""
CURRENT_COUNT=""
BUNDLE_ID=""
SHOW_DAILY="false"

usage() {
  cat <<'EOF'
用法: ./lightsail-capacity.sh [选项]

根据 AWS Lightsail 本月截至昨天的账单流量，计算应保持的实例数量。

选项:
  --region REGION                 AWS 区域，默认 ap-northeast-1
  --bundle-id ID                  指定 Lightsail bundleId
  --monthly-transfer-gb GB        单台整月流量额度，默认自动读取；模拟模式默认 2000
  --buffer RATIO                  安全余量，默认 0.10（10%）
  --as-of YYYY-MM-DD              计算日期，默认当前 UTC 日期
  --mock-used-gb GB               不访问账单，使用给定流量测试计算
  --current-count N               模拟模式的当前实例数
  --daily                         显示本月截至昨天的每日账单流量
  -h, --help                      显示帮助
EOF
}

die() {
  printf '错误: %s\n' "$1" >&2
  exit 1
}

is_nonnegative_number() {
  [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

validate_inputs() {
  is_nonnegative_number "$MONTHLY_TRANSFER_GB" || die "monthly-transfer-gb 必须是非负数字"
  awk -v value="$MONTHLY_TRANSFER_GB" 'BEGIN { exit !(value > 0) }' || die "monthly-transfer-gb 必须大于 0"
  is_nonnegative_number "$BUFFER" || die "buffer 必须是非负数字"
  awk -v value="$BUFFER" 'BEGIN { exit !(value >= 0 && value <= 1) }' || die "buffer 必须在 0 到 1 之间"
  [[ "$AS_OF" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "as-of 必须是有效的 YYYY-MM-DD 日期"
  local normalized_date
  normalized_date="$(date -u -d "$AS_OF" +%F 2>/dev/null)" || die "as-of 必须是有效的 YYYY-MM-DD 日期"
  [[ "$normalized_date" == "$AS_OF" ]] || die "as-of 必须是有效的 YYYY-MM-DD 日期"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

check_aws_identity() {
  local error
  if ! error="$(aws sts get-caller-identity --output json 2>&1)"; then
    die "无法读取 AWS 身份，请检查 CloudShell 凭证: $error"
  fi
}

resolve_bundle() {
  local bundles_json bundle_json error
  if ! bundles_json="$(aws lightsail get-bundles --no-include-inactive --region "$REGION" --output json 2>&1)"; then
    die "读取 Lightsail 套餐失败，需要 lightsail:GetBundles: $bundles_json"
  fi

  if [[ -n "$BUNDLE_ID" ]]; then
    bundle_json="$(jq -c --arg id "$BUNDLE_ID" '.bundles[]? | select(.bundleId == $id)' <<<"$bundles_json" | head -n 1)"
  else
    bundle_json="$(jq -c '
      .bundles[]?
      | select((.price | tonumber) == 7)
      | select((.ramSizeInGb | tonumber) == 1)
      | select(.supportedPlatforms | index("LINUX_UNIX"))
      | select(((.publicIpv4AddressCount // 0) | tonumber) > 0)
    ' <<<"$bundles_json" | head -n 1)"
  fi

  [[ -n "$bundle_json" ]] || die "没有找到符合条件的套餐；请使用 --bundle-id 和 --monthly-transfer-gb 明确指定"
  BUNDLE_ID="$(jq -r '.bundleId' <<<"$bundle_json")"
  if [[ "$MONTHLY_TRANSFER_SET" == "false" ]]; then
    MONTHLY_TRANSFER_GB="$(jq -r '.transferPerMonthInGb' <<<"$bundle_json")"
  fi
  is_nonnegative_number "$MONTHLY_TRANSFER_GB" || die "套餐流量额度不是有效数字"
  awk -v value="$MONTHLY_TRANSFER_GB" 'BEGIN { exit !(value > 0) }' || die "套餐月流量额度必须大于 0"
}

fetch_billed_transfer_gb() {
  local filter_json usage_json transfer_records
  filter_json="$(jq -nc --arg region "$REGION" '{And:[{Dimensions:{Key:"SERVICE",Values:["Amazon Lightsail"]}},{Dimensions:{Key:"REGION",Values:[$region]}}]}')"
  if ! usage_json="$(aws ce get-cost-and-usage \
    --time-period "Start=${MONTH_START},End=${AS_OF}" \
    --granularity DAILY \
    --metrics UsageQuantity \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --filter "$filter_json" \
    --output json 2>&1)"; then
    die "读取 Cost Explorer 失败，需要 ce:GetCostAndUsage: $usage_json"
  fi

  jq -e '(.ResultsByTime | type) == "array" and all(.ResultsByTime[]; (.Groups | type) == "array")' \
    >/dev/null 2>&1 <<<"$usage_json" || die "Cost Explorer 响应结构无效"
  jq -e 'all(.ResultsByTime[];
    (.TimePeriod.Start | type) == "string"
    and (.TimePeriod.Start | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and (.TimePeriod.End | type) == "string"
    and (.TimePeriod.End | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
  )' >/dev/null 2>&1 <<<"$usage_json" || die "Cost Explorer 日期结构无效"
  if ! transfer_records="$(jq -c '[
    .ResultsByTime[].Groups[]
    | select((.Keys | type) == "array" and (.Keys | length) > 0)
    | select(.Keys[0] | endswith("TotalDataXfer-In-Bytes") or endswith("TotalDataXfer-Out-Bytes"))
    | {key:.Keys[0], amount:.Metrics.UsageQuantity.Amount, unit:.Metrics.UsageQuantity.Unit}
  ]' <<<"$usage_json" 2>/dev/null)"; then
    die "Cost Explorer 流量记录解析失败"
  fi
  jq -e 'all(.[]; .unit == "GB")' >/dev/null 2>&1 <<<"$transfer_records" || die "Cost Explorer 流量单位不是 GB"
  jq -e 'all(.[]; (.amount | type) == "string" and (.amount | test("^[0-9]+([.][0-9]*)?$")))' \
    >/dev/null 2>&1 <<<"$transfer_records" || die "Cost Explorer 流量数值无效"

  BILLED_IN_GB="$(jq -r '[.[] | select(.key | endswith("TotalDataXfer-In-Bytes")) | .amount | tonumber] | add // 0' <<<"$transfer_records")"
  BILLED_OUT_GB="$(jq -r '[.[] | select(.key | endswith("TotalDataXfer-Out-Bytes")) | .amount | tonumber] | add // 0' <<<"$transfer_records")"
  DAILY_TRANSFER_JSON="$(jq -c '[
    .ResultsByTime[]
    | {
        date: .TimePeriod.Start,
        inbound: ([.Groups[]?
          | select((.Keys | type) == "array" and (.Keys | length) > 0)
          | select(.Keys[0] | endswith("TotalDataXfer-In-Bytes"))
          | .Metrics.UsageQuantity.Amount | tonumber] | add // 0),
        outbound: ([.Groups[]?
          | select((.Keys | type) == "array" and (.Keys | length) > 0)
          | select(.Keys[0] | endswith("TotalDataXfer-Out-Bytes"))
          | .Metrics.UsageQuantity.Amount | tonumber] | add // 0)
      }
  ]' <<<"$usage_json")"
  USED_GB="$(awk -v inbound="$BILLED_IN_GB" -v outbound="$BILLED_OUT_GB" 'BEGIN { printf "%.6f", inbound+outbound }')"
  if awk -v used="$USED_GB" 'BEGIN { exit !(used == 0) }'; then
    printf '警告: Cost Explorer 返回的流量为 0，账单数据可能仍在延迟。\n' >&2
  fi
}

count_current_instances() {
  local instances_json
  if ! instances_json="$(aws lightsail get-instances --region "$REGION" --output json 2>&1)"; then
    die "读取 Lightsail 实例失败，需要 lightsail:GetInstances: $instances_json"
  fi
  CURRENT_COUNT="$(jq -r --arg id "$BUNDLE_ID" '[.instances[]? | select(.bundleId == $id) | select((.state.name // "") != "terminated")] | length' <<<"$instances_json")"
  [[ "$CURRENT_COUNT" =~ ^[0-9]+$ ]] || die "当前实例数量不是有效整数"
}

calculate_capacity() {
  local used_gb="$1" completed_days="$2" remaining_days="$3"
  local days_in_month="$4" monthly_transfer_gb="$5" buffer="$6"

  DAILY_AVERAGE_GB="$(awk -v u="$used_gb" -v d="$completed_days" 'BEGIN { printf "%.12f", u/d }')"
  FORECAST_REMAINING_GB="$(awk -v u="$used_gb" -v d="$completed_days" -v r="$remaining_days" 'BEGIN { printf "%.12f", u/d*r }')"
  BUFFERED_DEMAND_GB="$(awk -v u="$used_gb" -v d="$completed_days" -v r="$remaining_days" -v b="$buffer" 'BEGIN { printf "%.12f", u/d*r*(1+b) }')"
  PER_INSTANCE_REMAINING_GB="$(awk -v q="$monthly_transfer_gb" -v r="$remaining_days" -v m="$days_in_month" 'BEGIN { printf "%.12f", q*r/m }')"
  REQUIRED_INSTANCES="$(awk -v u="$used_gb" -v d="$completed_days" -v r="$remaining_days" -v b="$buffer" -v q="$monthly_transfer_gb" -v m="$days_in_month" '
    BEGIN {
      ratio=(u/d*r*(1+b))/(q*r/m)
      rounded=int(ratio)
      print (ratio > rounded) ? rounded + 1 : rounded
    }
  ')"
}

format_tib() {
  awk -v gb="$1" 'BEGIN { printf "%.2f", gb/1024 }'
}

setup_colors() {
  COLOR_RESET=''
  COLOR_BOLD=''
  COLOR_CYAN=''
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_RED=''

  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_BOLD=$'\033[1m'
    COLOR_CYAN=$'\033[36m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_RED=$'\033[31m'
  fi
}

print_section() {
  printf '\n%s%s── %s ─────────────────────────────────────────%s\n' \
    "$COLOR_BOLD" "$COLOR_CYAN" "$1" "$COLOR_RESET"
}

print_daily_breakdown() {
  local date inbound outbound total

  print_section '每日流量明细'
  printf '%-12s %16s %16s %16s\n' '日期' '入站' '出站' '合计'
  printf '%s\n' '──────────────────────────────────────────────────────────────'
  while IFS=$'\t' read -r date inbound outbound; do
    total="$(awk -v i="$inbound" -v o="$outbound" 'BEGIN { printf "%.3f", i+o }')"
    printf '%-12s %12.3f GB %12.3f GB %12.3f GB\n' "$date" "$inbound" "$outbound" "$total"
  done < <(jq -r '.[] | [.date, .inbound, .outbound] | @tsv' <<<"$DAILY_TRANSFER_JSON")
}

print_report() {
  local used_gb="$1" completed_days="$2" remaining_days="$3" current_count="$4"
  local difference=$((REQUIRED_INSTANCES - current_count))
  local status_color status_text

  setup_colors

  printf '%s%s╭──────────────────────────────────────────────────────╮%s\n' "$COLOR_BOLD" "$COLOR_CYAN" "$COLOR_RESET"
  printf '%s%s│  AWS Lightsail 流量容量预测%s\n' "$COLOR_BOLD" "$COLOR_CYAN" "$COLOR_RESET"
  printf '%s%s╰──────────────────────────────────────────────────────╯%s\n' "$COLOR_BOLD" "$COLOR_CYAN" "$COLOR_RESET"

  print_section '基础信息'
  printf '区域: %s\n' "$REGION"
  if [[ -n "${BUNDLE_ID:-}" ]]; then
    printf '套餐: %s (%.0f GB/月)\n' "$BUNDLE_ID" "$MONTHLY_TRANSFER_GB"
  fi
  printf '计算日期（UTC）: %s\n' "$AS_OF"
  printf '已完成账单天数: %d 天\n' "$completed_days"
  printf '剩余天数: %d 天\n' "$remaining_days"

  print_section '流量概览'
  if [[ -n "${BILLED_IN_GB:-}" ]]; then
    printf '账单入站流量: %.3f GB  (%s TiB)\n' "$BILLED_IN_GB" "$(format_tib "$BILLED_IN_GB")"
    printf '账单出站流量: %.3f GB  (%s TiB)\n' "$BILLED_OUT_GB" "$(format_tib "$BILLED_OUT_GB")"
  fi
  printf '截至昨天总流量: %.3f GB  (%s TiB)\n' "$used_gb" "$(format_tib "$used_gb")"
  printf '日均总流量: %.3f GB/天\n' "$DAILY_AVERAGE_GB"

  if [[ "$SHOW_DAILY" == "true" ]]; then
    print_daily_breakdown
  fi

  print_section '月底预测'
  printf '预计剩余流量: %.3f GB  (%s TiB)\n' "$FORECAST_REMAINING_GB" "$(format_tib "$FORECAST_REMAINING_GB")"
  printf '安全余量: %.1f%%\n' "$(awk -v b="$BUFFER" 'BEGIN { print b*100 }')"
  printf '含安全余量需求: %.3f GB  (%s TiB)\n' "$BUFFERED_DEMAND_GB" "$(format_tib "$BUFFERED_DEMAND_GB")"

  print_section '容量建议'
  printf '单台剩余额度: %.3f GB  (%s TiB)\n' "$PER_INSTANCE_REMAINING_GB" "$(format_tib "$PER_INSTANCE_REMAINING_GB")"
  printf '当前实例数: %d 台\n' "$current_count"
  printf '建议保持实例数: %d 台\n' "$REQUIRED_INSTANCES"
  if (( difference > 0 )); then
    printf '建议新增: %d 台\n' "$difference"
    status_color="$COLOR_RED"
    status_text="✗ 容量不足：还需新增 $difference 台实例"
  elif (( difference < 0 )); then
    printf '当前多出: %d 台\n' "$((-difference))"
    status_color="$COLOR_GREEN"
    status_text="✓ 容量充足：当前多出 $((-difference)) 台实例"
  else
    printf '当前数量正好，无需调整。\n'
    status_color="$COLOR_GREEN"
    status_text='✓ 容量合适：无需调整实例数量'
  fi
  printf '\n%s%s%s%s\n' "$COLOR_BOLD" "$status_color" "$status_text" "$COLOR_RESET"
}

while (( $# > 0 )); do
  case "$1" in
    --region) REGION="${2:?--region 缺少参数}"; shift 2 ;;
    --bundle-id) BUNDLE_ID="${2:?--bundle-id 缺少参数}"; shift 2 ;;
    --monthly-transfer-gb) MONTHLY_TRANSFER_GB="${2:?--monthly-transfer-gb 缺少参数}"; MONTHLY_TRANSFER_SET="true"; shift 2 ;;
    --buffer) BUFFER="${2:?--buffer 缺少参数}"; shift 2 ;;
    --as-of) AS_OF="${2:?--as-of 缺少参数}"; shift 2 ;;
    --mock-used-gb) MOCK_USED_GB="${2:?--mock-used-gb 缺少参数}"; shift 2 ;;
    --current-count) CURRENT_COUNT="${2:?--current-count 缺少参数}"; shift 2 ;;
    --daily) SHOW_DAILY="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

require_command awk
require_command date
validate_inputs
[[ "$SHOW_DAILY" != "true" || -z "$MOCK_USED_GB" ]] || die "--daily 不能与 --mock-used-gb 同时使用"

DAY_OF_MONTH="$(date -u -d "$AS_OF" +%-d)"
MONTH_START="$(date -u -d "$AS_OF" +%Y-%m-01)"
DAYS_IN_MONTH="$(date -u -d "$MONTH_START +1 month -1 day" +%-d)"
COMPLETED_DAYS=$((DAY_OF_MONTH - 1))
REMAINING_DAYS=$((DAYS_IN_MONTH - COMPLETED_DAYS))
(( COMPLETED_DAYS > 0 )) || die "没有完整的账单日期；请在当月 2 日以后运行"

if [[ -n "$MOCK_USED_GB" ]]; then
  is_nonnegative_number "$MOCK_USED_GB" || die "mock-used-gb 必须是非负数字"
  [[ "$CURRENT_COUNT" =~ ^[0-9]+$ ]] || die "current-count 必须是非负整数"
  CURRENT_COUNT=$((10#$CURRENT_COUNT))
  USED_GB="$MOCK_USED_GB"
else
  require_command aws
  require_command jq
  check_aws_identity
  resolve_bundle
  fetch_billed_transfer_gb
  count_current_instances
fi

calculate_capacity "$USED_GB" "$COMPLETED_DAYS" "$REMAINING_DAYS" "$DAYS_IN_MONTH" "$MONTHLY_TRANSFER_GB" "$BUFFER"
print_report "$USED_GB" "$COMPLETED_DAYS" "$REMAINING_DAYS" "$CURRENT_COUNT"

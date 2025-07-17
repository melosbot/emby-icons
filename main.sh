#!/bin/bash

# 确保脚本出现错误时立即退出，并处理管道错误
set -eo pipefail

# --- 前置检查 ---
for cmd in jq curl file nproc awk sha256sum md5sum; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "❎ 错误: 核心依赖 '$cmd' 未安装。请先安装。" >&2
        exit 1
    fi
done

if [ ! -f "config.csv" ]; then
    echo "❎ 错误: 配置文件 'config.csv' 未找到！" >&2
    exit 1
fi

# --- URL & Path Configuration ---
GITHUB_REPOSITORY="$1"
ICON_ASSETS_DIR="icons/assets"
ALL_IN_ONE_JSON="icons/allinone.json"
BASE_CDN_URL=""

if [ -n "$GITHUB_REPOSITORY" ]; then
    BASE_CDN_URL="https://cdn.jsdelivr.net/gh/${GITHUB_REPOSITORY}@main/"
    echo "✅ CDN 基础URL已配置: ${BASE_CDN_URL}"
else
    echo "⚠️ 警告: 未提供GitHub仓库名称。将使用相对路径生成URL。"
fi

# --- 临时文件与目录设置 ---
temp_dir=$(mktemp -d -t emby_icons_XXXXXXXXXX)
trap 'rm -rf -- "$temp_dir"' EXIT

all_icons_jsonl="$temp_dir/all_icons.jsonl"
parallel_results_tsv="$temp_dir/parallel_results.tsv"
md5_map_tmp="$temp_dir/md5_map.json"
url_map_tmp="$temp_dir/url_map.json"
new_icons_normalized_tmp="$temp_dir/new_icons_normalized.tmp.json"
old_icons_archive_tmp="$temp_dir/old_icons_archive.tmp.json"
final_icons_tmp="$temp_dir/final_icons_array.tmp.json"

# --- 初始化 ---
mkdir -p "$ICON_ASSETS_DIR"
> "$all_icons_jsonl"; > "$parallel_results_tsv"; echo "{}" > "$md5_map_tmp"; echo "{}" > "$url_map_tmp"

# --- 函数定义 ---
get_ext_from_mime() {
    case "$1" in
        "image/png")     echo "png" ;; "image/jpeg")    echo "jpg" ;;
        "image/gif")     echo "gif" ;; "image/webp")    echo "webp" ;;
        "image/svg+xml") echo "svg" ;; *)               echo "" ;;
    esac
}

process_icon_entry() {
    local icon_json="$1"
    local url; url=$(echo "$icon_json" | jq -r '.url')
    [ -z "$url" ] || [ "$url" == "null" ] && return 1
    local temp_image_file; temp_image_file=$(mktemp -p "$temp_dir")
    if ! curl -fsSL --connect-timeout 10 --max-time 20 --retry 2 --retry-delay 2 "$url" -o "$temp_image_file"; then rm -f "$temp_image_file"; return 1; fi
    if [ ! -s "$temp_image_file" ]; then rm -f "$temp_image_file"; return 1; fi
    local mime_type; mime_type=$(file -b --mime-type "$temp_image_file")
    local ext; ext=$(get_ext_from_mime "$mime_type")
    if [ -z "$ext" ]; then rm -f "$temp_image_file"; return 1; fi
    local md5_hash; md5_hash=$(md5sum "$temp_image_file" | awk '{print $1}')
    local new_filepath="${ICON_ASSETS_DIR}/${md5_hash}.${ext}"
    if [ ! -f "$new_filepath" ]; then mv "$temp_image_file" "$new_filepath"; else rm -f "$temp_image_file"; fi
    printf "%s\t%s\t%s\t%s\n" "$md5_hash" "$new_filepath" "$url" "$icon_json"
}
export -f get_ext_from_mime process_icon_entry
export temp_dir ICON_ASSETS_DIR

# --- 脚本主逻辑 ---
echo "🔄 (1/4) 解析配置文件, 收集上游最新图标..."
while IFS=, read -r comment src_url path; do
    comment=$(echo "$comment" | xargs); src_url=$(echo "$src_url" | xargs); path=$(echo "$path" | xargs)
    [[ "$comment" =~ ^# ]] && continue; [ -z "$src_url" ] && continue
    echo "  - 处理源: $comment"
    author=$(basename "$path" | cut -d'_' -f1 | sed 's|icons/||')
    if downloaded_json=$(curl -fsSL --retry 2 "$src_url"); then
        if jq -e . >/dev/null 2>&1 <<<"$downloaded_json"; then
             # original_name 已废弃，但为保持兼容性暂时保留
             echo "$downloaded_json" | jq -c --arg author "$author" --arg source "$comment" '.icons[]?|select(.name!=null and .url!=null)|{name:.name,url:.url,author:$author,source:$source,original_name:(.name+"-"+$author)}' >> "$all_icons_jsonl"
        else echo "  ⚠️ 警告: 无法解析 '$comment' 的JSON。" >&2; fi
    else echo "  ⚠️ 警告: 无法下载 '$comment' 的源。" >&2; fi
done < "config.csv"

total_icons=$(wc -l < "$all_icons_jsonl")
if [ "$total_icons" -eq 0 ]; then
    echo "⚠️ 警告: 本次未能从上游收集到任何图标。将保持现有'allinone.json'不变。"
else
    cores=$(nproc)
    echo -e "\n📊 (2/4) 收集完成, 共 $total_icons 条目. 将使用 ${cores} 核心并发处理..."
    cat "$all_icons_jsonl" | xargs -d '\n' -P "${cores}" -I {} bash -c 'process_icon_entry "$@"' _ {} >> "$parallel_results_tsv" || true
    processed_count=$(wc -l < "$parallel_results_tsv")
    echo -e "  > 本地化处理完成. 成功处理 $processed_count / $total_icons 个图标。\n"
fi

# [阶段 3/4] 归档式聚合图标库 (allinone.json) - 只增不减
echo "🔧 (3/4) 归档式聚合结果以生成 '$ALL_IN_ONE_JSON'..."
while IFS=$'\t' read -r md5_hash new_filepath original_url icon_json; do
    final_url="${BASE_CDN_URL}${new_filepath}"
    jq --arg md5 "$md5_hash" --argjson icon "$icon_json" --arg url "$final_url" 'if .[$md5] then .[$md5].aliases += [$icon] else .[$md5] = {primary: $icon, aliases: [], url: $url} end' "$md5_map_tmp" > "$md5_map_tmp.tmp" && mv "$md5_map_tmp.tmp" "$md5_map_tmp"
    jq --arg orig_url "$original_url" --arg new_url "$final_url" '.[$orig_url] = $new_url' "$url_map_tmp" > "$url_map_tmp.tmp" && mv "$url_map_tmp.tmp" "$url_map_tmp"
done < "$parallel_results_tsv"

# 1. 【核心修正】生成本次运行的、格式绝对正确的图标列表
#    这个列表将作为合并的基准 (master list)
jq '[ to_entries[] | .value | {
    name: .primary.name,
    url: .url,
    description: (
        "来源: \(.primary.source) " +
        (if .aliases | length > 0 then "| 别名(来自其他源的相同图标): \((.aliases | map(.original_name)) | join(", "))" else "" end)
    )
} ]' "$md5_map_tmp" > "$new_icons_normalized_tmp"

# 2. 如果旧的allinone.json存在, 提取它的图标列表用于比对和补充
if [ -f "$ALL_IN_ONE_JSON" ] && [ -s "$ALL_IN_ONE_JSON" ] && jq -e . >/dev/null 2>&1 < "$ALL_IN_ONE_JSON"; then
    jq '.icons' "$ALL_IN_ONE_JSON" > "$old_icons_archive_tmp"
else
    echo "[]" > "$old_icons_archive_tmp"
fi

# 3. 【最终合并逻辑】
#    - 先把新列表和旧列表中的所有图标都放到一个大数组里
#    - 然后，按 URL 去重。这里使用 `group_by(.url)` 并取每组的第一个，确保了新列表中的条目优先被保留（因为新列表在前）。
#    - 最后按纯名称排序
jq -s '(.[0] + .[1]) | group_by(.url) | map(.[0]) | sort_by(.name)' "$new_icons_normalized_tmp" "$old_icons_archive_tmp" > "$final_icons_tmp"

# 4. 生成最终的 allinone.json
final_count=$(jq 'length' "$final_icons_tmp")
all_authors=$(jq -r '[.[] | .description | split(" | ")[0] | sub("来源: "; "")] | unique | join(", ")' "$final_icons_tmp")

mkdir -p "$(dirname "$ALL_IN_ONE_JSON")"
jq -n \
  --arg name "Emby Icons" \
  --arg desc "所有图标均已本地化存储于本仓库，并通过 jsDelivr CDN 提供服务。包含来自 ${all_authors:-'多个作者'} 的作品。当前共收录 ${final_count} 个独立图标。" \
  --slurpfile icons "$final_icons_tmp" \
  '{ "name": $name, "description": $desc, "icons": $icons[0] }' > "$ALL_IN_ONE_JSON"

echo "✅ 成功生成归档文件 '$ALL_IN_ONE_JSON'！最终图标数量: ${final_count}"

# [阶段 4/4] 镜像式重写独立的配置文件
echo -e "\n✍️ (4/4) 开始镜像式重写各独立的JSON配置文件..."
while IFS=, read -r comment src_url path; do
    comment=$(echo "$comment" | xargs); src_url=$(echo "$src_url" | xargs); path=$(echo "$path" | xargs)
    [[ "$comment" =~ ^# ]] && continue; [ -z "$src_url" ] && continue
    echo "  - 重写: $path"
    if downloaded_json=$(curl -fsSL --retry 2 "$src_url"); then
        if jq -e . >/dev/null 2>&1 <<<"$downloaded_json"; then
            jq --slurpfile url_map "$url_map_tmp" --arg name "$comment (CDN镜像版)" --arg desc "此配置文件是源的镜像，所有图标通过 jsDelivr CDN 提供。源自: $src_url" '.name = $name | .description = $desc | .icons |= map(.url |= (if $url_map[0][.] then $url_map[0][.] else . end))' <<< "$downloaded_json" > "$path"
        fi
    fi
done < "config.csv"

echo "✅ 所有独立的配置文件已更新为镜像模式。"
echo "🎉 全部任务完成！"
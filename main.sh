#!/bin/bash

# 确保脚本出现错误时立即退出，并处理管道错误
set -eo pipefail

# --- 前置检查 ---
for cmd in jq curl file nproc awk sha256sum md5sum; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ 错误: 核心依赖 '$cmd' 未安装。请先安装。" >&2
        exit 1
    fi
done

if [ ! -f "config.csv" ]; then
    echo "❌ 错误: 配置文件 'config.csv' 未找到！" >&2
    exit 1
fi

# --- 核心定义 ---
# 永久存储所有图标图片的地方
ICON_ASSETS_DIR="icons/assets"
# 输出的主聚合文件名
ALL_IN_ONE_JSON="icons/allinone.json"

# --- 临时文件与目录设置 ---
temp_dir=$(mktemp -d -t emby_icons_XXXXXXXXXX)
trap 'rm -rf -- "$temp_dir"' EXIT # 脚本退出时自动清理

# 定义各类临时文件
all_icons_jsonl="$temp_dir/all_icons.jsonl"
parallel_results_tsv="$temp_dir/parallel_results.tsv"
md5_map_tmp="$temp_dir/md5_map.json"
url_map_tmp="$temp_dir/url_map.json"
final_icons_tmp="$temp_dir/final_icons_array.tmp.json"

# --- 初始化 ---
mkdir -p "$ICON_ASSETS_DIR"
# 清理并创建空的临时文件
> "$all_icons_jsonl"
> "$parallel_results_tsv"
echo "{}" > "$md5_map_tmp"
echo "{}" > "$url_map_tmp"

# --- 函数定义 ---

# 函数: 从MIME类型获取文件扩展名
get_ext_from_mime() {
    local mime_type="$1"
    case "$mime_type" in
        "image/png")     echo "png" ;;
        "image/jpeg")    echo "jpg" ;;
        "image/gif")     echo "gif" ;;
        "image/webp")    echo "webp" ;;
        "image/svg+xml") echo "svg" ;;
        *)               echo "" ;; # 返回空表示不支持或未知
    esac
}

# 函数: 并发工作单元 (Worker) - 下载、校验、哈希、存储图片，并输出结果
process_icon_entry() {
    local icon_json="$1"
    local url; url=$(echo "$icon_json" | jq -r '.url')

    if [ -z "$url" ] || [ "$url" == "null" ]; then return 1; fi

    local temp_image_file; temp_image_file=$(mktemp -p "$temp_dir")

    # 下载图片，忽略 4xx/5xx 错误，因为源可能失效
    if ! curl -fsSL --connect-timeout 10 --max-time 20 --retry 2 --retry-delay 2 "$url" -o "$temp_image_file"; then
        rm -f "$temp_image_file"
        return 1
    fi

    # 校验文件是否为有效图片
    if [ ! -s "$temp_image_file" ]; then rm -f "$temp_image_file"; return 1; fi
    local mime_type; mime_type=$(file -b --mime-type "$temp_image_file")
    local ext; ext=$(get_ext_from_mime "$mime_type")
    if [ -z "$ext" ]; then rm -f "$temp_image_file"; return 1; fi

    # 计算MD5并生成新路径
    local md5_hash; md5_hash=$(md5sum "$temp_image_file" | awk '{print $1}')
    local new_filepath="${ICON_ASSETS_DIR}/${md5_hash}.${ext}"

    # 如果文件不存在，则移动过去；否则删除临时文件
    if [ ! -f "$new_filepath" ]; then
        mv "$temp_image_file" "$new_filepath"
    else
        rm -f "$temp_image_file"
    fi
    
    # 输出 TSV 格式: MD5哈希, 新的本地路径, 原始URL, 原始图标JSON对象
    printf "%s\t%s\t%s\t%s\n" "$md5_hash" "$new_filepath" "$url" "$icon_json"
}

# 导出函数和变量，供 xargs 使用
export -f get_ext_from_mime process_icon_entry
export temp_dir ICON_ASSETS_DIR

# --- 脚本主逻辑 ---

# [阶段 1/4] 解析配置文件，收集所有图标条目
echo "🔄 (1/4) 解析配置文件并收集所有图标条目..."
while IFS=, read -r comment src_url path; do
    # 去除首尾空格
    comment=$(echo "$comment" | xargs)
    src_url=$(echo "$src_url" | xargs)
    path=$(echo "$path" | xargs)
    
    # 跳过注释行和空行
    [[ "$comment" =~ ^# ]] && continue
    [ -z "$src_url" ] && continue

    echo "  - 处理源: $comment"
    # 下载原始JSON文件，并将每个图标对象提取为单独一行
    author=$(basename "$path" | cut -d'_' -f1 | sed 's|icons/||')
    if downloaded_json=$(curl -fsSL "$src_url"); then
        if jq -e . >/dev/null 2>&1 <<<"$downloaded_json"; then
             echo "$downloaded_json" | jq -c --arg author "$author" --arg source "$comment" \
               '.icons[]? | select(.name != null and .url != null) | {name: .name, url: .url, author: $author, source: $source, original_name: (.name + "-" + $author)}' \
               >> "$all_icons_jsonl"
        else
            echo "  ⚠️ 警告: 无法解析来自 '$comment' 的JSON。" >&2
        fi
    else
        echo "  ⚠️ 警告: 无法下载来自 '$comment' 的源。" >&2
    fi
done < "config.csv"

total_icons=$(wc -l < "$all_icons_jsonl")
if [ "$total_icons" -eq 0 ]; then
    echo "❌ 错误: 未能从任何源收集到图标。请检查 'config.csv' 和网络连接。" >&2
    mkdir -p "$(dirname "$ALL_IN_ONE_JSON")" && echo '{ "name": "Emby图标库", "description": "未能收集到任何图标。", "icons": [] }' > "$ALL_IN_ONE_JSON"
    exit 0
fi

cores=$(nproc)
echo -e "\n📊 (2/4) 图标收集完成，共计 $total_icons 个条目。"
echo "    > 将使用 ${cores} 个核心并发下载、处理并存储图片，这可能需要一些时间..."

# [阶段 2/4] 并发处理所有图标
cat "$all_icons_jsonl" | xargs -d '\n' -P "${cores}" -I {} bash -c 'process_icon_entry "$@"' _ {} >> "$parallel_results_tsv" || true

processed_count=$(wc -l < "$parallel_results_tsv")
echo -e "    > 本地化处理完成。共成功处理 $processed_count / $total_icons 个图标。\n"

# [阶段 3/4] 构建映射关系并生成聚合图标库 (allinone.json)
echo "聚合结果并生成 '$ALL_IN_ONE_JSON'..."

# 从处理结果中构建一个MD5映射（用于去重）和一个URL映射（用于重写）
while IFS=$'\t' read -r md5_hash new_filepath original_url icon_json; do
    # 更新MD5映射
    jq --arg md5 "$md5_hash" --argjson icon "$icon_json" --arg url "$new_filepath" '
        if .[$md5] then .[$md5].aliases += [$icon]
        else .[$md5] = {primary: $icon, aliases: [], url: $url}
        end
    ' "$md5_map_tmp" > "$md5_map_tmp.tmp" && mv "$md5_map_tmp.tmp" "$md5_map_tmp"

    # 更新URL映射
    jq --arg orig_url "$original_url" --arg new_url "$new_filepath" '
        .[$orig_url] = $new_url
    ' "$url_map_tmp" > "$url_map_tmp.tmp" && mv "$url_map_tmp.tmp" "$url_map_tmp"
done < "$parallel_results_tsv"

# 生成图标数组并存入临时文件，绕开参数长度限制
jq '
    [
        to_entries[] | .value |
        {
            name: (.primary.name + "-" + .primary.author),
            url: .url,
            description: (if .aliases | length > 0 then "别名: " + ([.aliases[].original_name] | join(", ")) else .primary.source end)
        }
    ] | sort_by(.name)
' "$md5_map_tmp" > "$final_icons_tmp"

# 获取统计信息
final_count=$(jq 'length' "$final_icons_tmp")
duplicate_count=$((processed_count - final_count))
authors=$(jq -r '.[].primary.author' "$md5_map_tmp" | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')

# 使用 `slurpfile` 从文件安全地合并 JSON，生成最终的 allinone.json 文件
mkdir -p "$(dirname "$ALL_IN_ONE_JSON")"
jq -n \
  --arg name "Emby图标库" \
  --arg desc "通过MD5去重并整合了包含来自 ${authors:-'N/A'} 的所有图标源。原始图标 ${processed_count} 个，去重后保留 ${final_count} 个，移除了 ${duplicate_count} 个重复项。图标按名称排序，重复的来源已在描述中注明。" \
  --slurpfile icons "$final_icons_tmp" \
  '{ "name": $name, "description": $desc, "icons": $icons[0] }' > "$ALL_IN_ONE_JSON"

echo "✅ 成功生成 '$ALL_IN_ONE_JSON'！"
echo "    - 最终图标数量: ${final_count}"
echo "    - 移除重复数量: ${duplicate_count}"

# [阶段 4/4] 使用URL映射重写独立的配置文件
echo -e "\n🔧 (4/4) 开始重写各独立的JSON配置文件..."
while IFS=, read -r comment src_url path; do
    comment=$(echo "$comment" | xargs); src_url=$(echo "$src_url" | xargs); path=$(echo "$path" | xargs)
    [[ "$comment" =~ ^# ]] && continue
    [ -z "$src_url" ] && continue

    echo "  - 重写: $path"
    if downloaded_json=$(curl -fsSL "$src_url"); then
        if jq -e . >/dev/null 2>&1 <<<"$downloaded_json"; then
            # 使用 URL map 来替换 json 中的链接
            # 更新name和description，并替换所有图标的url
            jq --slurpfile url_map "$url_map_tmp" \
               --arg name "$comment" \
               --arg desc "此配置文件中的所有图标资源均已缓存到本仓库，确保稳定访问。源自: $src_url" '
               .name = $name | 
               .description = $desc | 
               .icons |= map(.url |= (if $url_map[0][.] then $url_map[0][.] else . end))
            ' <<< "$downloaded_json" > "$path"
        fi
    fi
done < "config.csv"

echo "✅ 所有独立的配置文件已更新为本地资源路径。"
echo "🎉 全部任务完成！"
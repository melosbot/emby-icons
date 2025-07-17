#!/bin/bash

# 确保脚本出现错误时立即退出，并处理管道错误
set -eo pipefail

# --- 全局常量与配置 ---
readonly GITHUB_REPOSITORY="$1"
readonly ICON_ASSETS_DIR="icons/assets"
readonly ALL_IN_ONE_JSON="icons/allinone.json"
readonly TEMP_DIR=$(mktemp -d -t emby_icons_XXXXXXXXXX)
trap 'rm -rf -- "$TEMP_DIR"' EXIT

BASE_CDN_URL=""
if [ -n "$GITHUB_REPOSITORY" ]; then
    BASE_CDN_URL="https://cdn.jsdelivr.net/gh/${GITHUB_REPOSITORY}@main/"
fi

# --- 日志函数 ---
# LOG_LEVEL: 0:DEBUG, 1:INFO, 2:WARN, 3:ERROR
readonly LOG_LEVEL=1
log() {
    local level="$1"
    local message="$2"
    local color_error="\033[0;31m"
    local color_warn="\033[0;33m"
    local color_info="\033[0;32m"
    local color_step="\033[0;34m"
    local color_reset="\033[0m"
    local prefix

    case "$level" in
        "ERROR") (( LOG_LEVEL <= 3 )) && prefix="${color_error}❎ "  ;;
        "WARN")  (( LOG_LEVEL <= 2 )) && prefix="${color_warn}⚠️ "   ;;
        "INFO")  (( LOG_LEVEL <= 1 )) && prefix="${color_info}✅ "   ;;
        "STEP")  (( LOG_LEVEL <= 1 )) && prefix="${color_debug}🚀 "  ;;
        "DEBUG") (( LOG_LEVEL <= 0 )) && prefix="${color_debug}🐛 "  ;;
        *)       prefix="   " ;;
    esac

    [ -n "$prefix" ] && echo -e "${prefix}${message}${color_reset}" >&2
}

# --- 核心函数 ---
get_ext_from_mime() {
    case "$1" in
        "image/png")     echo "png" ;; "image/jpeg")    echo "jpg" ;;
        "image/gif")     echo "gif" ;; "image/webp")    echo "webp" ;;
        "image/svg+xml") echo "svg" ;; *)               echo ""    ;;
    esac
}

process_icon_entry() {
    local url icon_json
    url="$1"
    icon_json="$2"
    local temp_image_file
    
    temp_image_file=$(mktemp -p "$TEMP_DIR")
    if ! curl -fsSL --connect-timeout 8 --max-time 15 --retry 2 "$url" -o "$temp_image_file"; then rm -f "$temp_image_file"; return 1; fi
    if [ ! -s "$temp_image_file" ]; then rm -f "$temp_image_file"; return 1; fi
    
    local mime_type ext md5_hash new_filepath
    mime_type=$(file -b --mime-type "$temp_image_file")
    ext=$(get_ext_from_mime "$mime_type")
    if [ -z "$ext" ]; then rm -f "$temp_image_file"; return 1; fi
    
    md5_hash=$(md5sum "$temp_image_file" | awk '{print $1}')
    new_filepath="${ICON_ASSETS_DIR}/${md5_hash}.${ext}"
    
    [ ! -f "$new_filepath" ] && mv "$temp_image_file" "$new_filepath" || rm -f "$temp_image_file"
    
    printf "%s\t%s\t%s\t%s\n" "$md5_hash" "$new_filepath" "$url" "$icon_json"
}
export -f get_ext_from_mime process_icon_entry
export TEMP_DIR ICON_ASSETS_DIR

# --- 程序入口 ---
main() {
    log "STEP" "环境检查与初始化..."
    for cmd in jq curl file nproc awk md5sum; do
        ! command -v "$cmd" &> /dev/null && log "ERROR" "核心依赖 '$cmd' 未安装。" && exit 1
    done
    [ ! -f "config.csv" ] && log "ERROR" "配置文件 'config.csv' 未找到！" && exit 1
    mkdir -p "$ICON_ASSETS_DIR"
    log "INFO" "环境就绪。"
    
    log "STEP" "解析 config.csv 并收录所有上游图标..."
    local all_icons_jsonl="$TEMP_DIR/all_icons.jsonl"
    
    grep -v '^\s*#' config.csv | grep -v '^\s*$' | while IFS=, read -r comment src_url path; do
        comment=$(echo "$comment" | xargs); src_url=$(echo "$src_url" | xargs); path=$(echo "$path" | xargs)
        log " " "  - 处理源: $comment"
        author=$(basename "$path" | cut -d'_' -f1 | sed 's|icons/||')
        if downloaded_json=$(curl -fsSL --retry 2 "$src_url"); then
             echo "$downloaded_json" | jq -c --arg author "$author" --arg source "$comment" \
                '.icons[]? | select(.name != null and .url != null) | {name: .name, url: .url, author: $author, source: $source}' >> "$all_icons_jsonl"
        else
            log "WARN" "无法下载或解析源: $comment ($src_url)"
        fi
    done

    local total_to_process; total_to_process=$(wc -l < "$all_icons_jsonl")
    if [ "$total_to_process" -eq 0 ]; then
        log "WARN" "config.csv 中未找到有效的上游源，将仅使用历史数据生成文件。"
    else
        log "STEP" "共发现 ${total_to_process} 个图标条目，开始并行本地化..."
        local parallel_results_tsv="$TEMP_DIR/parallel_results.tsv"
        
        # 【修正点】将jq的输出正确格式化，让xargs能够安全地处理。每行一个URL，一个JSON对象。
        jq -r '[.url, .] | @sh' "$all_icons_jsonl" | xargs -n 2 -P"$(nproc)" bash -c 'process_icon_entry "$@"' _ >> "$parallel_results_tsv" || true
        
        local processed_count; processed_count=$(wc -l < "$parallel_results_tsv")
        log "INFO" "成功处理 ${processed_count} / ${total_to_process} 个图标资源。"
    fi

    log "STEP" "聚合数据并生成永久归档的 allinone.json..."
    local md5_map_tmp="$TEMP_DIR/md5_map.json"
    local url_map_tmp="$TEMP_DIR/url_map.json"
    echo "{}" > "$md5_map_tmp"
    echo "{}" > "$url_map_tmp"
    
    # 【修正点】恢复使用稳定可靠的 while read 循环来构建映射
    if [ -f "$parallel_results_tsv" ]; then
        while IFS=$'\t' read -r md5_hash new_filepath original_url icon_json; do
            final_url="${BASE_CDN_URL}${new_filepath}"
            jq --arg md5 "$md5_hash" --argjson icon "$icon_json" --arg url "$final_url" \
               '.[$md5] |= (if . then .aliases += [$icon] else {primary: $icon, aliases: [], url: $url} end)' "$md5_map_tmp" > "$md5_map_tmp.tmp" && mv "$md5_map_tmp.tmp" "$md5_map_tmp"
            jq --arg orig_url "$original_url" --arg new_url "$final_url" \
               '.[$orig_url] = $new_url' "$url_map_tmp" > "$url_map_tmp.tmp" && mv "$url_map_tmp.tmp" "$url_map_tmp"
        done < "$parallel_results_tsv"
    fi

    local new_icons_normalized_tmp="$TEMP_DIR/new_icons.json"
    local old_icons_archive_tmp="$TEMP_DIR/old_icons.json"
    local final_icons_tmp="$TEMP_DIR/final_allinone.json"
    
    jq '[.[] | {
        name: .primary.name,
        url: .url,
        description: ("来源: " + .primary.source + (if .aliases | length > 0 then " | 别名(来自其他源的相同图标): " + ([.aliases[].author] | unique | map(. + "的" + .primary.name) | join(", ")) else "" end))
    }]' "$md5_map_tmp" > "$new_icons_normalized_tmp"

    if [ -f "$ALL_IN_ONE_JSON" ] && [ -s "$ALL_IN_ONE_JSON" ]; then
         jq '.icons' "$ALL_IN_ONE_JSON" > "$old_icons_archive_tmp"
    else
        echo "[]" > "$old_icons_archive_tmp"
    fi

    jq -s '(.[0] + .[1]) | group_by(.url) | map(.[0]) | sort_by(.name)' "$new_icons_normalized_tmp" "$old_icons_archive_tmp" > "$final_icons_tmp"

    local final_count; final_count=$(jq 'length' "$final_icons_tmp")
    local all_authors; all_authors=$(cut -d, -f1 config.csv | grep -v '^\s*#' | grep -v '^\s*$' | xargs | tr ' ' ',' | sed 's/,$//; s/,/, /g')

    jq -n --arg name "Emby Icons" \
      --arg desc "所有图标均已本地化存储于本仓库，并通过 jsDelivr CDN 提供服务。包含来自 ${all_authors:-多个作者} 的作品。当前共收录 ${final_count} 个独立图标。" \
      --slurpfile icons "$final_icons_tmp" \
      '{name: $name, description: $desc, icons: $icons[0]}' > "$ALL_IN_ONE_JSON"
    log "INFO" "成功生成 ${ALL_IN_ONE_JSON}，共 ${final_count} 个图标。"

    log "STEP" "重写独立的镜像 JSON 文件..."
    grep -v '^\s*#' config.csv | grep -v '^\s*$' | while IFS=, read -r comment src_url path; do
        comment=$(echo "$comment" | xargs); src_url=$(echo "$src_url" | xargs); path=$(echo "$path" | xargs)
        log " " "  - 更新: $path"
        if downloaded_json=$(curl -fsSL --retry 2 "$src_url"); then
            jq --slurpfile url_map "$url_map_tmp" --arg name "$comment (CDN镜像版)" \
               --arg desc "此配置文件是源的镜像，所有图标通过jsDelivr CDN提供。源自: $src_url" \
               '.name = $name | .description = $desc | .icons |= map(.url |= (if $url_map[0][.] then $url_map[0][.] else . end))' \
               <<< "$downloaded_json" > "$path"
        fi
    done
    log "INFO" "所有独立的配置文件更新完成。"

    log "STEP" "所有任务执行完毕！"
}

if [ $# -eq 0 ] && [ -n "$GITHUB_ACTION" ]; then
    log "ERROR" "在 GitHub Actions 环境中运行时，必须提供仓库名称作为第一个参数。"
    exit 1
fi
main "$@"
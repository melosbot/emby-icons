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
readonly LOG_LEVEL=1
log() {
    local level="$1"; local message="$2"
    local color_error="\033[0;31m"; local color_warn="\033[0;33m"
    local color_info="\033[0;32m"; local color_step="\033[0;34m"; local color_reset="\033[0m"
    local prefix
    case "$level" in
        "ERROR") (( LOG_LEVEL <= 3 )) && prefix="${color_error}❎ ";;
        "WARN")  (( LOG_LEVEL <= 2 )) && prefix="${color_warn}⚠️ " ;;
        "INFO")  (( LOG_LEVEL <= 1 )) && prefix="${color_info}✅ " ;;
        "STEP")  (( LOG_LEVEL <= 1 )) && prefix="${color_step}🚀 " ;;
        *)       prefix="   " ;;
    esac
    [ -n "$prefix" ] && echo -e "${prefix}${message}${color_reset}" >&2
}

# --- 核心函数 ---
get_ext_from_mime() {
    case "$1" in
        "image/png") echo "png"  ;; "image/jpeg") echo "jpg"   ;; "image/gif") echo "gif";;
        "image/webp") echo "webp";; "image/svg+xml") echo "svg";; *) echo ""             ;;
    esac
}

# 并发工作单元：只负责下载URL并输出 MD5 和新路径的映射
download_and_map_url() {
    local url="$1"; local temp_image_file;
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
    
    # 输出 TSV 格式: 原始URL, 新的CDN URL, MD5
    printf "%s\t%s\t%s\n" "$url" "${BASE_CDN_URL}${new_filepath}" "$md5_hash"
}
export -f get_ext_from_mime download_and_map_url
export TEMP_DIR ICON_ASSETS_DIR BASE_CDN_URL

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
    local url_to_cdn_map="$TEMP_DIR/url_to_cdn.map"
    if (( total_to_process == 0 )); then
        log "WARN" "config.csv 中未找到有效上游源，将仅使用历史数据生成文件。"
    else
        log "STEP" "共发现 ${total_to_process} 个图标条目，开始并行下载和处理..."
        # 提取所有唯一的URL进行处理
        jq -r '.url' "$all_icons_jsonl" | sort -u | xargs -n 1 -P"$(nproc)" bash -c 'download_and_map_url "$@"' _ > "$url_to_cdn_map" || true
        
        local processed_count; processed_count=$(wc -l < "$url_to_cdn_map")
        log "INFO" "成功处理 ${processed_count} 个唯一的图标资源。"
    fi

    log "STEP" "聚合数据并生成永久归档的 allinone.json..."
    
    # 构建一个 jq 脚本来将 all_icons.jsonl 中的原始URL替换为新的CDN URL
    local url_map_jq_filter;
    url_map_jq_filter=$(awk -F'\t' '{printf "if .url == \"%s\" then .url = \"%s\" else ", $1, $2}' "$url_to_cdn_map" | tr -d '\n' | sed 's/else $//' )
    url_map_jq_filter+=". end" # 闭合所有 if-then-else
    
    local md5_map_jq_filter;
    md5_map_jq_filter=$(awk -F'\t' '{printf "if .url == \"%s\" then .md5 = \"%s\" else ", $2, $3}' "$url_to_cdn_map" | tr -d '\n' | sed 's/else $//' )
    md5_map_jq_filter+=". end"

    # 执行替换和聚合
    local new_icons_normalized_tmp="$TEMP_DIR/new_icons.json"
    jq -c "$url_map_jq_filter" "$all_icons_jsonl" | jq -c "$md5_map_jq_filter" | \
    jq -s '
        group_by(.md5) |
        map({
            primary: .[0],
            aliases: (.[1:] | map(.author + "的" + .name)),
            url: .[0].url
        }) |
        map({
            name: .primary.name,
            url: .url,
            description: ("来源: " + .primary.source + (if .aliases | length > 0 then " | 别名(来自其他源的相同图标): " + (.aliases | join(", ")) else "" end))
        })' > "$new_icons_normalized_tmp"

    local old_icons_archive_tmp="$TEMP_DIR/old_icons.json"
    local final_icons_tmp="$TEMP_DIR/final_allinone.json"
    if [ -f "$ALL_IN_ONE_JSON" ] && [ -s "$ALL_IN_ONE_JSON" ]; then
         jq '.icons' "$ALL_IN_ONE_JSON" > "$old_icons_archive_tmp" || echo "[]" > "$old_icons_archive_tmp"
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
    # 构建一个用于替换独立文件的jq过滤器
    local individual_files_filter;
    individual_files_filter=$(awk -F'\t' '{printf ".icons |= map(if .url == \"%s\" then .url = \"%s\" else . end)", $1, $2}' "$url_to_cdn_map" | tr '\n' ' | ')
    individual_files_filter=${individual_files_filter%??} # 移除最后的 " | "
    
    grep -v '^\s*#' config.csv | grep -v '^\s*$' | while IFS=, read -r comment src_url path; do
        comment=$(echo "$comment" | xargs); src_url=$(echo "$src_url" | xargs); path=$(echo "$path" | xargs)
        log " " "  - 更新: $path"
        if downloaded_json=$(curl -fsSL --retry 2 "$src_url"); then
            jq --arg name "$comment (CDN镜像版)" --arg desc "此配置文件是源的镜像，所有图标通过jsDelivr CDN提供。源自: $src_url" \
               '.name = $name | .description = $desc' <<< "$downloaded_json" | \
            jq "$individual_files_filter" > "$path"
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
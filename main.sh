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
    
    printf "%s\t%s\t%s\n" "$url" "${BASE_CDN_URL}${new_filepath}" "$md5_hash"
}
export -f get_ext_from_mime download_and_map_url
export TEMP_DIR ICON_ASSETS_DIR BASE_CDN_URL

# --- 程序入口 ---
main() {
    log "STEP" "环境检查与初始化..."
    for cmd in jq curl file nproc awk md5sum sort join; do
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

    local total_urls; total_urls=$(jq -r '.url' "$all_icons_jsonl" | sort -u | wc -l)
    local url_map_tsv="$TEMP_DIR/url_map.tsv"
    if (( total_urls == 0 )); then
        log "WARN" "未发现任何有效的图标URL，将仅使用历史数据。"
    else
        log "STEP" "共发现 ${total_urls} 个唯一的图标URL，开始并行下载..."
        jq -r '.url' "$all_icons_jsonl" | sort -u | xargs -n 1 -P"$(nproc)" bash -c 'download_and_map_url "$@"' _ > "$url_map_tsv" || true
        
        local processed_count; processed_count=$(wc -l < "$url_map_tsv")
        log "INFO" "成功处理 ${processed_count} / ${total_urls} 个唯一的图标资源。"
    fi

    log "STEP" "聚合数据并生成永久归档的 allinone.json..."
    
    # 准备用于 join 的两个文件
    local icons_data_tsv="$TEMP_DIR/icons_data.tsv"
    jq -r '[.url, .] | @tsv' "$all_icons_jsonl" | sort -k1,1 > "$icons_data_tsv"
    sort -k1,1 "$url_map_tsv" -o "$url_map_tsv"

    # 使用 join 合并数据
    local joined_data_tsv="$TEMP_DIR/joined_data.tsv"
    join -t $'\t' -1 1 -2 1 "$icons_data_tsv" "$url_map_tsv" > "$joined_data_tsv"
    
    local new_icons_normalized_tmp="$TEMP_DIR/new_icons.json"
    jq -s -R '
        split("\n") | .[] | select(length > 0) |
        split("\t") | 
        (.[1] | fromjson) as $icon_details |
        {
            "name": $icon_details.name,
            "author": $icon_details.author,
            "source": $icon_details.source,
            "new_url": .[2],
            "md5": .[3]
        }' "$joined_data_tsv" | \
    jq -s '
        group_by(.md5) |
        map({
            primary: .[0],
            aliases: (.[1:] | map(.author + "的" + .name)),
            url: .[0].new_url
        }) |
        map({
            name: .primary.name,
            url: .url,
            description: ("来源: " + .primary.source + (if .aliases | length > 0 then " | 别名: " + (.aliases | join(", ")) else "" end))
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
    local url_replace_sed; url_replace_sed=$(awk -F'\t' '{printf "s|%s|%s|g;", $1, $2}' "$url_map_tsv")
    
    grep -v '^\s*#' config.csv | grep -v '^\s*$' | while IFS=, read -r comment src_url path; do
        comment=$(echo "$comment" | xargs); src_url=$(echo "$src_url" | xargs); path=$(echo "$path" | xargs)
        log " " "  - 更新: $path"
        if downloaded_json=$(curl -fsSL --retry 2 "$src_url"); then
            echo "$downloaded_json" | sed "$url_replace_sed" | \
            jq --arg name "$comment (CDN镜像版)" --arg desc "此配置文件是源的镜像，所有图标通过jsDelivr CDN提供。源自: $src_url" \
               '.name = $name | .description = $desc' > "$path"
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
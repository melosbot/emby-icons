import os
import csv
import json
import hashlib
import sys
import time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.parse import urlparse

import requests

# --- 全局配置 ---
CONFIG_FILE = Path("config.csv")
ICON_ASSETS_DIR = Path("icons/assets")
ALL_IN_ONE_JSON = Path("icons/allinone.json")
UPDATE_LOG_FILE = Path("update.log")
BASE_CDN_URL = ""

# --- MIME 类型到文件扩展名的映射 ---
MIME_TO_EXT = {
    "image/png": "png",  "image/jpeg": "jpg",
    "image/gif": "gif",  "image/webp": "webp",
    "image/svg+xml": "svg",
}

def get_session():
    """创建一个带有重试机制的 requests.Session"""
    session = requests.Session()
    adapter = requests.adapters.HTTPAdapter(
        pool_connections=100,
        pool_maxsize=100,
        max_retries=3
    )
    session.mount('http://', adapter)
    session.mount('https://', adapter)
    return session

def process_icon_entry(session: requests.Session, icon_data: dict) -> dict | None:
    """
    下载、处理单个图标，并返回其元数据。
    """
    url = icon_data.get("url")
    if not url:
        return None

    try:
        response = session.get(url, timeout=20, stream=True)
        response.raise_for_status()

        content = response.content
        if not content:
            print(f"  ⚠️ 警告: 下载内容为空. URL: {url}", file=sys.stderr)
            return None

        mime_type = response.headers.get("Content-Type", "").split(";")[0].strip()
        ext = MIME_TO_EXT.get(mime_type)
        if not ext:
            print(f"  ⚠️ 警告: 不支持的 MIME 类型 '{mime_type}'. URL: {url}", file=sys.stderr)
            return None

        md5_hash = hashlib.md5(content).hexdigest()
        file_size = len(content)
        new_filepath = ICON_ASSETS_DIR / f"{md5_hash}.{ext}"

        if not new_filepath.exists():
            new_filepath.write_bytes(content)

        return {
            "primary": icon_data,
            "md5": md5_hash,
            "size": file_size,
            "filepath": new_filepath,
            "original_url": url,
        }
    except requests.exceptions.RequestException as e:
        print(f"  - 错误: 下载失败. URL: {url}", file=sys.stderr)
        return None

def main():
    """脚本主入口"""
    start_time = time.time()
    
    # 从 GitHub Actions 获取仓库名称以构建 CDN URL
    if len(sys.argv) > 1 and sys.argv[1]:
        global BASE_CDN_URL
        BASE_CDN_URL = f"https://cdn.jsdelivr.net/gh/{sys.argv[1]}@main/"
        print(f"✅ CDN 基础URL已配置: {BASE_CDN_URL}")
    else:
        print("⚠️ 警告: 未提供GitHub仓库名称。将使用相对路径生成URL。", file=sys.stderr)

    ICON_ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    if UPDATE_LOG_FILE.exists():
        UPDATE_LOG_FILE.unlink()

    # 1. 解析配置文件，收集上游图标
    print("\n🔄 (1/4) 解析配置文件, 收集上游最新图标...")
    all_icons_to_process = []
    url_map = {}
    if not CONFIG_FILE.is_file():
        print(f"❎ 错误: 配置文件 '{CONFIG_FILE}' 未找到！", file=sys.stderr)
        sys.exit(1)

    with CONFIG_FILE.open("r", encoding="utf-8") as f:
        reader = csv.reader(filter(lambda row: row and not row[0].strip().startswith('#'), f))
        for row in reader:
            if len(row) < 3: continue
            comment, src_url, path_str = [item.strip() for item in row]
            print(f"  - 处理源: {comment}")
            try:
                resp = requests.get(src_url, timeout=10)
                resp.raise_for_status()
                source_json = resp.json()
                author = Path(path_str).name.split("_")[0]
                
                # 镜像重写原始 JSON
                mirrored_json = source_json.copy()
                mirrored_json["name"] = f"{comment} (CDN镜像版)"
                mirrored_json["description"] = f"源自: {src_url}"
                # 预先写入一份，后续填充 URL
                Path(path_str).write_text(json.dumps(mirrored_json, indent=2, ensure_ascii=False), encoding="utf-8")

                for icon in source_json.get("icons", []):
                    if icon.get("name") and icon.get("url"):
                        all_icons_to_process.append({
                            "name": icon["name"],
                            "url": icon["url"],
                            "author": author,
                            "source": comment,
                            "original_name": f"{icon['name']}-{author}"
                        })
            except Exception as e:
                print(f"  ⚠️ 警告: 无法处理源 '{comment}'. URL: {src_url}, 错误: {e}", file=sys.stderr)

    # 2. 并发处理图标
    total_to_process = len(all_icons_to_process)
    print(f"\n📊 (2/4) 收集完成, 共 {total_to_process} 条目. 开始并发处理...")
    
    processed_results = []
    with ThreadPoolExecutor(max_workers=os.cpu_count() * 2) as executor:
        session = get_session()
        futures = {executor.submit(process_icon_entry, session, icon): icon for icon in all_icons_to_process}
        for future in as_completed(futures):
            result = future.result()
            if result:
                processed_results.append(result)

    print(f"  - 本地化处理完成. 成功处理 {len(processed_results)} / {total_to_process} 个图标。")

    # 3. 聚合图标库 (allinone.json)
    print(f"\n⚒️ (3/4) 归档式聚合结果以生成 '{ALL_IN_ONE_JSON}'...")
    md5_map = {}
    for result in processed_results:
        md5 = result["md5"]
        final_url = f"{BASE_CDN_URL}{result['filepath'].as_posix()}"
        url_map[result["original_url"]] = final_url
        
        if md5 not in md5_map:
            md5_map[md5] = {
                "primary": result["primary"],
                "aliases": [],
                "url": final_url,
                "size": result["size"]
            }
        else:
            md5_map[md5]["aliases"].append(result["primary"])

    new_normalized_icons = []
    for md5, data in md5_map.items():
        description = f"来源: {data['primary']['source']}"
        if data['aliases']:
            alias_names = ", ".join(alias['original_name'] for alias in data['aliases'])
            description += f" | 别名: {alias_names}"
        
        new_normalized_icons.append({
            "md5": md5,
            "name": data["primary"]["name"],
            "url": data["url"],
            "size": data.get("size", 0),
            "description": description,
        })
        
    old_icons = []
    if ALL_IN_ONE_JSON.exists() and ALL_IN_ONE_JSON.stat().st_size > 0:
        try:
            old_icons = json.loads(ALL_IN_ONE_JSON.read_text(encoding="utf-8")).get("icons", [])
        except json.JSONDecodeError:
            print(f"⚠️ 警告: '{ALL_IN_ONE_JSON}' 文件损坏，将重新创建。")
    
    all_icons_map = {icon['url']: icon for icon in old_icons}
    all_icons_map.update({icon['url']: icon for icon in new_normalized_icons})
    final_icons_list = list(all_icons_map.values())
    
    final_icons_list.sort(key=lambda x: (x['name'].lower(), -x.get('size', 0)))

    old_count = len(old_icons)
    final_count = len(final_icons_list)
    
    if final_count <= old_count:
        print(f"  - 图标库已是最新，无需更新 '{ALL_IN_ONE_JSON}'。图标数量: {final_count}")
    else:
        print(f"  - 检测到新增图标！将更新 '{ALL_IN_ONE_JSON}'。 旧: {old_count}, 新: {final_count}")
        old_urls = {icon['url'] for icon in old_icons}
        new_icons = [icon for icon in final_icons_list if icon['url'] not in old_urls]
        if new_icons:
            log_lines = [f'"{icon["md5"]}": {icon["name"]}' for icon in new_icons]
            UPDATE_LOG_FILE.write_text("\n".join(log_lines), encoding="utf-8")
        
        all_authors = ", ".join(sorted(list(set(
            Path(row[2].strip()).name.split("_")[0]
            for row in csv.reader(filter(lambda r: r and not r[0].strip().startswith('#'), CONFIG_FILE.open("r", encoding="utf-8"))) if len(row) > 2
        ))))
        
        final_json_output = {
            "name": "Emby Icons",
            "description": f"包含来自 {all_authors} 的作品。当前共收录 {final_count} 个独立图标。",
            "icons": final_icons_list
        }
        ALL_IN_ONE_JSON.write_text(json.dumps(final_json_output, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"  - 成功生成归档文件 '{ALL_IN_ONE_JSON}'！")

    # 4. 镜像重写独立的 JSON 配置文件
    print(f"\n✍️ (4/4) 开始镜像式重写各独立的JSON配置文件...")
    with CONFIG_FILE.open("r", encoding="utf-8") as f:
        reader = csv.reader(filter(lambda row: row and not row[0].strip().startswith('#'), f))
        for row in reader:
             if len(row) < 3: continue
             _comment, _src_url, path_str = [item.strip() for item in row]
             path = Path(path_str)
             if path.exists():
                 print(f"  - 重写: {path}")
                 content = json.loads(path.read_text(encoding="utf-8"))
                 content["icons"] = [
                     {**icon, "url": url_map.get(icon["url"], icon["url"])}
                     for icon in content.get("icons", [])
                 ]
                 path.write_text(json.dumps(content, indent=2, ensure_ascii=False), encoding="utf-8")

    print("\n🎉 全部任务完成！")
    print(f"⏱️ 总耗时: {time.time() - start_time:.2f} 秒。")

if __name__ == "__main__":
    main()
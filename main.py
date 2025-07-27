import os
import csv
import json
import hashlib
import sys
import time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from typing import List, Dict, Tuple, Optional

import requests
from requests.adapters import HTTPAdapter

# --- 类型定义与数据类 ---
@dataclass
class Config:
    """应用程序的全局配置"""
    repo_name: Optional[str] = None
    config_file: Path = Path("config.csv")
    icon_assets_dir: Path = Path("icons/assets")
    all_in_one_json: Path = Path("icons/allinone.json")
    update_log_file: Path = Path("update.log")
    commit_message_file: Path = Path("commit_message.txt")
    github_event_name: Optional[str] = os.getenv("GITHUB_EVENT_NAME")

    @property
    def base_cdn_url(self) -> str:
        """根据仓库名称动态生成CDN基础URL"""
        if self.repo_name:
            return f"https://cdn.jsdelivr.net/gh/{self.repo_name}@main/"
        return ""

@dataclass
class SourceConfig:
    """代表 config.csv 中的一个源"""
    comment: str
    src_url: str
    path: Path
    author: str

@dataclass
class IconData:
    """代表一个待处理的图标条目"""
    name: str
    url: str
    author: str
    source: str
    original_name: str

@dataclass
class ProcessResult:
    """代表一个已成功处理的图标结果"""
    primary: IconData
    md5: str
    size: int
    filepath: Path
    original_url: str

# --- 全局常量 ---
MIME_TO_EXT = {
    "image/png": "png",  "image/jpeg": "jpg",
    "image/gif": "gif",  "image/webp": "webp",
    "image/svg+xml": "svg",
}

# --- 核心功能函数 ---
def get_session() -> requests.Session:
    """创建一个带有重试机制的 requests.Session"""
    session = requests.Session()
    adapter = HTTPAdapter(pool_connections=100,
                          pool_maxsize=100, max_retries=3)
    session.mount('http://', adapter)
    session.mount('https://', adapter)
    return session

def setup_environment(config: Config):
    """创建必要的目录并清理旧的日志文件"""
    config.icon_assets_dir.mkdir(parents=True, exist_ok=True)
    if config.update_log_file.exists():
        config.update_log_file.unlink()
    if config.commit_message_file.exists():
        config.commit_message_file.unlink()

def parse_arguments() -> Config:
    """解析命令行参数以构建配置对象"""
    repo_name = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
    config = Config(repo_name=repo_name)

    if config.base_cdn_url:
        print(f"✅ CDN 基础URL已配置: {config.base_cdn_url}")
    else:
        print("⚠️ 警告: 未提供GitHub仓库名称。将使用相对路径生成URL。", file=sys.stderr)
    return config

def load_sources_from_csv(config_file: Path) -> List[SourceConfig]:
    """从CSV配置文件中加载所有图标源"""
    sources = []
    if not config_file.is_file():
        print(f"❎ 错误: 配置文件 '{config_file}' 未找到！", file=sys.stderr)
        sys.exit(1)

    with config_file.open("r", encoding="utf-8") as f:
        reader = csv.reader(
            filter(lambda row: row and not row[0].strip().startswith('#'), f))
        for row in reader:
            if len(row) < 3:
                continue
            comment, src_url, path_str = [item.strip() for item in row]
            author = Path(path_str).name.split("_")[0]
            sources.append(SourceConfig(
                comment=comment, src_url=src_url, path=Path(path_str), author=author
            ))
    return sources

def fetch_upstream_icons(sources: List[SourceConfig], session: requests.Session) -> Tuple[List[IconData], Dict[Path, Dict]]:
    """从所有上游源获取图标定义"""
    all_icons_to_process = []
    source_jsons = {}
    print("\n🔄 (1/4) 解析配置文件, 收集上游最新图标...")
    for source in sources:
        print(f"  - 处理源: {source.comment}")
        try:
            resp = session.get(source.src_url, timeout=10)
            resp.raise_for_status()
            source_json = resp.json()
            source_jsons[source.path] = source_json

            for icon in source_json.get("icons", []):
                if icon.get("name") and icon.get("url"):
                    all_icons_to_process.append(IconData(
                        name=icon["name"], url=icon["url"], author=source.author,
                        source=source.comment, original_name=f"{icon['name']}-{source.author}"
                    ))
        except requests.exceptions.RequestException as e:
            print(
                f"  - 警告: 网络请求失败 '{source.comment}'. URL: {source.src_url}", file=sys.stderr)
        except json.JSONDecodeError as e:
            print(
                f"  - 警告: JSON解析失败 '{source.comment}'. URL: {source.src_url}", file=sys.stderr)
    return all_icons_to_process, source_jsons

def process_icon_entry(session: requests.Session, icon_data: IconData, assets_dir: Path) -> Optional[ProcessResult]:
    """下载、处理单个图标，并返回其元数据"""
    try:
        response = session.get(icon_data.url, timeout=20, stream=True)
        response.raise_for_status()
        content = response.content
        if not content:
            print(f"  - 警告: 下载内容为空. URL: {icon_data.url}", file=sys.stderr)
            return None

        mime_type = response.headers.get(
            "Content-Type", "").split(";")[0].strip()
        ext = MIME_TO_EXT.get(mime_type)
        if not ext:
            print(
                f"  - 警告: 不支持的 MIME 类型 '{mime_type}'. URL: {icon_data.url}", file=sys.stderr)
            return None

        md5_hash = hashlib.md5(content).hexdigest()
        new_filepath = assets_dir / f"{md5_hash}.{ext}"
        if not new_filepath.exists():
            new_filepath.write_bytes(content)

        return ProcessResult(
            primary=icon_data, md5=md5_hash, size=len(content),
            filepath=new_filepath, original_url=icon_data.url
        )
    except requests.exceptions.RequestException:
        print(f"  - 错误: 下载失败. URL: {icon_data.url}", file=sys.stderr)
        return None

def process_icons_concurrently(icons: List[IconData], assets_dir: Path) -> List[ProcessResult]:
    """使用线程池并发处理所有图标"""
    total = len(icons)
    print(f"\n📊 (2/4) 收集完成, 共 {total} 条目. 开始并发处理...")
    results = []
    with ThreadPoolExecutor(max_workers=os.cpu_count() * 2) as executor:
        session = get_session()
        futures = {executor.submit(
            process_icon_entry, session, icon, assets_dir): icon for icon in icons}
        for future in as_completed(futures):
            result = future.result()
            if result:
                results.append(result)
    print(f"  - 本地化处理完成. 成功处理 {len(results)} / {total} 个图标。")
    return results

def update_allinone_json(results: List[ProcessResult], sources: List[SourceConfig], config: Config) -> Tuple[Dict[str, str], List[Dict]]:
    """聚合结果、更新 allinone.json 并返回 URL 映射和新增图标列表"""
    print(f"\n⚒️ (3/4) 归档式聚合结果以生成 '{config.all_in_one_json}'...")

    url_map, md5_map = {}, {}
    for res in results:
        final_url = f"{config.base_cdn_url}{res.filepath.as_posix()}"
        url_map[res.original_url] = final_url
        if res.md5 not in md5_map:
            md5_map[res.md5] = {"primary": res.primary,
                                "aliases": [], "url": final_url, "size": res.size}
        else:
            md5_map[res.md5]["aliases"].append(res.primary)

    new_normalized_icons = []
    for md5, data in md5_map.items():
        primary: IconData = data["primary"]
        description = f"来源: {primary.source}"
        if data['aliases']:
            description += f" | 别名: {', '.join(alias.original_name for alias in data['aliases'])}"
        new_normalized_icons.append(
            {"md5": md5, "name": primary.name, "url": data["url"], "size": data["size"], "description": description})

    old_icons = []
    if config.all_in_one_json.exists() and config.all_in_one_json.stat().st_size > 0:
        try:
            old_icons = json.loads(config.all_in_one_json.read_text(
                encoding="utf-8")).get("icons", [])
        except json.JSONDecodeError:
            print(f"  - 警告: '{config.all_in_one_json}' 文件损坏，将重新创建。")

    old_count = len(old_icons)
    all_icons_map = {icon['url']: icon for icon in old_icons}
    all_icons_map.update({icon['url']: icon for icon in new_normalized_icons})
    final_icons_list = sorted(all_icons_map.values(), key=lambda x: (
        x['name'].lower(), -x.get('size', 0)))
    final_count = len(final_icons_list)

    newly_added = []
    if final_count > old_count:
        print(
            f"  - 检测到新增图标！将更新 '{config.all_in_one_json}'。 旧: {old_count}, 新: {final_count}")
        old_urls = {icon['url'] for icon in old_icons}
        newly_added = [
            icon for icon in final_icons_list if icon['url'] not in old_urls]
        if newly_added:
            log_lines = [
                f'"{icon["md5"]}": {icon["name"]}' for icon in newly_added]
            config.update_log_file.write_text(
                "\n".join(log_lines), encoding="utf-8")

        all_authors = ", ".join(sorted(list(set(s.author for s in sources))))
        final_json = {"name": "Emby Icons",
                      "description": f"包含来自 {all_authors} 的作品。当前共收录 {final_count} 个独立图标。", "icons": final_icons_list}
        config.all_in_one_json.write_text(json.dumps(
            final_json, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"  - 成功生成归档文件 '{config.all_in_one_json}'！")
    else:
        print(
            f"  - 图标库已是最新，无需更新 '{config.all_in_one_json}'。图标数量: {final_count}")

    return url_map, newly_added

def generate_commit_message(newly_added: List[Dict], config: Config):
    """根据更新结果生成提交信息并写入文件"""
    print(f"  - 生成提交信息...")
    commit_msg_lines = []
    if newly_added:
        icon_count = len(newly_added)
        commit_msg_subject = f"feat: 新增 {icon_count} 个图标"
        commit_msg_lines.append(commit_msg_subject)
        commit_msg_lines.append("")
        commit_msg_lines.append(f"将 {icon_count} 个新图标添加到 allinone.json。")
        commit_msg_lines.append("")
        commit_msg_lines.append("新增图标列表 (最多显示10个):")
        for icon in newly_added[:10]:
            commit_msg_lines.append(f"  - {icon['name']}")
        
        if icon_count > 10:
            commit_msg_lines.append(f"... 及其他 {icon_count - 10} 个。")
    else:
        event_name = config.github_event_name
        if event_name == "schedule":
            commit_msg_subject = "chore(Scheduled): 同步上游图标库"
        elif event_name == "workflow_dispatch":
            commit_msg_subject = "chore(Manual): 同步上游图标库"
        else:
            commit_msg_subject = "chore(Auto): 同步上游图标库"
        commit_msg_lines.append(commit_msg_subject)
        commit_msg_lines.append("")
        commit_msg_lines.append("例行更新，未检测到新增图标。")

    commit_msg_lines.append("")
    commit_msg_lines.append(f"更新时间: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    
    config.commit_message_file.write_text("\n".join(commit_msg_lines), encoding="utf-8")
    print(f"  - 提交信息已生成到 '{config.commit_message_file}'")

def rewrite_source_json_files(sources: List[SourceConfig], source_jsons: Dict[Path, Dict], url_map: Dict[str, str]):
    """使用CDN URL重写各个独立的JSON配置文件"""
    print(f"\n✍️ (4/4) 开始镜像式重写各独立的JSON配置文件...")
    for source in sources:
        if source.path not in source_jsons:
            continue

        print(f"  - 重写: {source.path}")
        content = source_jsons[source.path].copy()
        content["name"] = f"{source.comment} (CDN镜像版)"
        content["description"] = f"源自: {source.src_url}"
        content["icons"] = [{**icon, "url": url_map.get(icon.get("url"), icon.get(
            "url"))} for icon in content.get("icons", []) if icon.get("url")]
        source.path.write_text(json.dumps(
            content, indent=2, ensure_ascii=False), encoding="utf-8")

def main():
    """脚本主入口，负责编排整个流程"""
    start_time = time.time()
    config = parse_arguments()
    setup_environment(config)
    sources = load_sources_from_csv(config.config_file)
    session = get_session()
    icons_to_process, source_jsons = fetch_upstream_icons(sources, session)
    processed_results = process_icons_concurrently(
        icons_to_process, config.icon_assets_dir)
    url_map, newly_added = update_allinone_json(processed_results, sources, config)
    generate_commit_message(newly_added, config)
    rewrite_source_json_files(sources, source_jsons, url_map)
    print(f"\n🎉 全部任务完成！总耗时: {time.time() - start_time:.2f} 秒。")

if __name__ == "__main__":
    main()

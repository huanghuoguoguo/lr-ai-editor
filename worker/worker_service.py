# ==============================================================================
# LR AI Editor: HTTP Service Worker
# ==============================================================================
# 常驻后台服务，接收 Lightroom 的 HTTP 请求，调用 AI 分析图片
# 启动方式: python worker_service.py --port 5000

import argparse
import base64
import json
import os
import sys
import threading
import traceback
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs

# 添加当前目录到 path，确保能导入 config
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config
from worker import analyze_image, truncate_text


class AIEditorHandler(BaseHTTPRequestHandler):
    """处理 Lightroom 发来的分析请求"""

    def log_message(self, format, *args):
        """自定义日志格式"""
        print(f"[{self.log_date_time_string()}] {format % args}", flush=True)

    def do_GET(self):
        """健康检查"""
        if self.path == "/health" or self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "service": "lr-ai-editor"}).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        """处理分析请求"""
        try:
            # 解析 URL
            parsed = urlparse(self.path)
            if parsed.path != "/analyze":
                self.send_response(404)
                self.end_headers()
                return

            # 读取请求体
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length == 0:
                self.send_error(400, "No content")
                return

            body = self.rfile.read(content_length)

            # 尝试解析 JSON
            try:
                request_data = json.loads(body.decode("utf-8"))
            except json.JSONDecodeError as e:
                self.send_error(400, f"Invalid JSON: {e}")
                return

            # 提取参数
            image_path = request_data.get("image_path")
            model = request_data.get("model", config.DEFAULT_MODEL)
            style_prompt = request_data.get("style_prompt", "")
            current_settings = request_data.get("current_settings")
            metadata = request_data.get("metadata")

            if not image_path:
                self.send_error(400, "Missing image_path")
                return

            print(f"分析请求: image={image_path}, model={model}", flush=True)

            # 检查图片是否存在
            if not os.path.exists(image_path):
                self.send_error(400, f"Image not found: {image_path}")
                return

            # 调用分析函数 (同步包装异步)
            import asyncio
            try:
                result = asyncio.run(analyze_image(
                    image_path=image_path,
                    model=model,
                    style_prompt=style_prompt,
                    current_settings=current_settings,
                    metadata=metadata,
                ))
            except Exception as e:
                print(f"分析失败: {e}", flush=True)
                traceback.print_exc()
                result = {
                    "advice": f"分析失败: {str(e)}",
                    "error": str(e),
                    "exposure": 0,
                    "contrast": 0,
                    "highlights": 0,
                    "shadows": 0,
                    "saturation": 0,
                    "temperature": 6500,
                    "tint": 0,
                }

            # 返回结果
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            response_json = json.dumps(result, ensure_ascii=False, indent=2)
            self.wfile.write(response_json.encode("utf-8"))
            print(f"分析完成: advice={result.get('advice', 'N/A')}", flush=True)

        except Exception as e:
            print(f"请求处理失败: {e}", flush=True)
            traceback.print_exc()
            self.send_error(500, f"Internal error: {e}")


def run_server(port: int):
    """启动 HTTP 服务"""
    server_address = ("127.0.0.1", port)
    httpd = HTTPServer(server_address, AIEditorHandler)
    print(f"LR AI Editor 服务启动在 http://127.0.0.1:{port}", flush=True)
    print(f"API 端点:", flush=True)
    print(f"  GET  /health  - 健康检查", flush=True)
    print(f"  POST /analyze - 分析图片", flush=True)
    print(f"按 Ctrl+C 停止服务", flush=True)
    httpd.serve_forever()


def main():
    parser = argparse.ArgumentParser(description="LR AI Editor HTTP Service")
    parser.add_argument("--port", type=int, default=5000, help="服务端口 (默认 5000)")
    args = parser.parse_args()

    run_server(args.port)


if __name__ == "__main__":
    main()
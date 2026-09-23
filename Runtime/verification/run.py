"""Offline real-JSC integration check. No app data or paid model requests."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / 'Runtime'
requests = []
leaks = []

class Sink(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        leaks.append(dict(self.headers))
        self.send_response(500)
        self.end_headers()

sink = ThreadingHTTPServer(('127.0.0.1', 0), Sink)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(self.path)
        if self.path.startswith('/anthropic'):
            assert self.headers.get('x-api-key') == 'fixture-secret'
        else:
            assert self.headers.get('authorization') == 'Bearer fixture-secret'
        if self.path.startswith('/unauthorized'):
            self.send_response(401)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"invalid fixture credential"}}')
            return
        if self.path.startswith('/redirect'):
            self.send_response(307)
            self.send_header('Location', f'http://127.0.0.1:{sink.server_port}/leak')
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        def write(value):
            data = value.encode()
            for i in range(0, len(data), 7):
                self.wfile.write(data[i:i + 7])
                self.wfile.flush()
        def chunk(delta, finish=None):
            value = {'id': 'fixture', 'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}
            write('data: ' + json.dumps(value, ensure_ascii=False) + '\n\n')
        try:
            if self.path.startswith('/anthropic'):
                events = [
                    {'type': 'message_start', 'message': {'id': 'msg', 'type': 'message', 'role': 'assistant', 'model': 'fixture', 'content': [], 'stop_reason': None, 'usage': {'input_tokens': 1, 'output_tokens': 0}}},
                    {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}},
                    {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': '東京，待确认。'}},
                    {'type': 'content_block_stop', 'index': 0},
                    {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'}, 'usage': {'output_tokens': 3}},
                    {'type': 'message_stop'},
                ]
                for event in events: write(f'event: {event["type"]}\ndata: {json.dumps(event, ensure_ascii=False)}\n\n')
                return
            if self.path.startswith('/slow'):
                chunk({'content': 'waiting'})
                time.sleep(1)
                chunk({'content': 'LATE'})
                chunk({}, 'stop')
            elif any(m['role'] == 'tool' for m in body['messages']):
                assert any('pending_confirmation 東京' in m.get('content', '') for m in body['messages'] if m['role'] == 'tool')
                chunk({'content': '東京，待确认。'})
                chunk({}, 'stop')
            else:
                chunk({'tool_calls': [{'index': 0, 'id': 'call-1', 'type': 'function', 'function': {'name': 'propose_expense', 'arguments': '{"amount":'}}]})
                chunk({'tool_calls': [{'index': 0, 'function': {'arguments': '"12.50"}'}}]}, 'tool_calls')
            write('data: [DONE]\n\n')
        except (BrokenPipeError, ConnectionResetError): pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
for service in [server, sink]: threading.Thread(target=service.serve_forever, daemon=True).start()
try:
    subprocess.run(['npm', 'run', 'build'], cwd=RUNTIME, check=True)
    ios = '--ios' in sys.argv
    sdk_name = 'iphonesimulator' if ios else 'macosx'
    sdk = subprocess.check_output(['xcrun', '--sdk', sdk_name, '--show-sdk-path'], text=True).strip()
    binary = RUNTIME / 'dist' / ('verify-ios' if ios else 'verify-mac')
    subprocess.run(['xcrun', '--sdk', sdk_name, 'swiftc', '-swift-version', '6', '-parse-as-library',
                    '-sdk', sdk, '-target', 'arm64-apple-ios26.0-simulator' if ios else 'arm64-apple-macosx26.0',
                    str(ROOT / 'Packages/LedgerKit/Sources/AgentClient/PiAgentRuntime.swift'),
                    str(RUNTIME / 'verification/Probe.swift'), '-o', str(binary)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True)
    args = [str(binary), str(RUNTIME / 'dist/agent.js'), f'http://127.0.0.1:{server.server_port}']
    if ios:
        # Explicit device selection; never change another project's simulator or erase app data.
        device = sys.argv[sys.argv.index('--ios') + 1]
        args = ['xcrun', 'simctl', 'spawn', device, *args]
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    (RUNTIME / 'dist' / ('ios.log' if ios else 'mac.log')).write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr)
    result.check_returncode()
    assert not leaks, 'cross-origin redirect was followed'
    assert len(requests) == 9, f'unexpected requests/retries: {requests}'
    print('PASS: 9 requests; no retries or credential leak')
finally:
    server.shutdown()
    sink.shutdown()

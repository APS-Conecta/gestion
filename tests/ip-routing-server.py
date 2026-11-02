import http.server, ssl, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"nextcloud-spreed-signaling":"Welcome","version":"fixture"}'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
server=http.server.HTTPServer(('0.0.0.0',443), Handler)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1],sys.argv[2])
server.socket=context.wrap_socket(server.socket,server_side=True)
server.serve_forever()

"""Real disposable loopback HTTP servers without unrelated reverse DNS.

HTTPServer normally calls socket.getfqdn during binding. These fixtures already
bind a numeric local address and never use a hostname, so preserve the real TCP
bind and assigned port without waiting for DNS. Product discovery is unchanged.
"""
import http.server
import socketserver


class LoopbackHTTPServer(http.server.HTTPServer):
    def server_bind(self):
        if self.server_address[0] != "127.0.0.1":
            raise ValueError("fixture_requires_numeric_loopback")
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


class LoopbackThreadingHTTPServer(socketserver.ThreadingMixIn, LoopbackHTTPServer):
    daemon_threads = True

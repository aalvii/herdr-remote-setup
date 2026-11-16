#!/usr/bin/env python3

import http.client
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAIR = os.path.join(ROOT, "host", "pair.py")


class Server:
    def __init__(self, pin="123456", once=False):
        self.work = tempfile.mkdtemp(prefix="herdr-pair-test-")
        self.state = os.path.join(self.work, "state")
        self.auth = os.path.join(self.work, "authorized_keys")
        os.makedirs(self.state)
        with open(self.auth, "w", encoding="utf-8") as handle:
            handle.write("# test\n")
        command = [
            sys.executable, PAIR, "--bind", "127.0.0.1", "--port", "0",
            "--pin", pin, "--state-dir", self.state,
            "--authorized-keys", self.auth,
        ]
        if once:
            command.append("--once")
        self.proc = subprocess.Popen(
            command,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            self.port = self._wait_port()
            self.pin = self.read_pin()
        except Exception:
            self.stop()
            raise

    def _wait_port(self):
        path = os.path.join(self.state, "pair.port")
        for _ in range(200):
            if os.path.exists(path):
                text = open(path, encoding="utf-8").read().strip()
                if text:
                    return int(text)
            time.sleep(0.05)
        raise RuntimeError("pair.py did not start")

    def read_pin(self):
        return open(os.path.join(self.state, "pair.pin"), encoding="utf-8").read().strip()

    def key(self, name):
        path = os.path.join(self.work, name)
        subprocess.run(
            ["ssh-keygen", "-t", "ed25519", "-N", "", "-f", path, "-q"],
            check=True)
        return open(path + ".pub", encoding="utf-8").read().strip()

    def post(self, pin, key):
        body = json.dumps({"pin": pin, "name": "test", "publicKey": key})
        return self.post_body(body)

    def post_body(self, body):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.request("POST", "/api/request", body,
                         {"Content-Type": "application/json"})
            response = conn.getresponse()
            return response.status, json.loads(response.read().decode("utf-8"))
        finally:
            conn.close()

    def get_info(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request("GET", "/api/info")
            response = conn.getresponse()
            return response.status, json.loads(response.read().decode("utf-8"))
        finally:
            conn.close()

    def keys(self):
        return open(self.auth, encoding="utf-8").read()

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        shutil.rmtree(self.work, ignore_errors=True)


def main():
    if not shutil.which("ssh-keygen"):
        print("ssh-keygen is required")
        return 2

    passed = 0
    failed = 0

    def check(name, condition, detail=""):
        nonlocal passed, failed
        if condition:
            print("ok %s" % name)
            passed += 1
        else:
            print("FAIL %s%s" % (name, (" " + detail) if detail else ""))
            failed += 1

    servers = []
    try:
        server = Server()
        servers.append(server)
        key = server.key("first")

        status, info = server.get_info()
        check("info service", status == 200 and info.get("service") == "herdr-pair", str(info))
        check("info user", bool(info.get("user")), str(info))

        status, body = server.post("000000", key)
        check("wrong pin is 401", status == 401 and body.get("ok") is False, "%s %s" % (status, body))
        check("wrong pin keeps pin", server.read_pin() == server.pin)

        status, body = server.post("é", key)
        check("non-ascii pin is 401", status == 401 and body.get("error") == "bad pin", "%s %s" % (status, body))
        check("non-ascii pin keeps pin", server.read_pin() == server.pin)

        status, body = server.post_body("[]")
        check("non-object json is 400", status == 400 and body.get("error") == "bad json", "%s %s" % (status, body))

        status, body = server.post(server.pin, key)
        check("correct pin is 200", status == 200 and body.get("ok") is True, "%s %s" % (status, body))
        check("key is appended", key.split()[1] in server.keys())
        next_pin = server.read_pin()
        check("pin rotates", next_pin != server.pin)

        status, body = server.post(next_pin, key)
        check("duplicate key is 200", status == 200 and body.get("alreadyPresent") is True, "%s %s" % (status, body))
        check("duplicate key is not appended twice", server.keys().count(key.split()[1]) == 1)

        def post_concurrently(target, keys, label):
            results = []
            barrier = threading.Barrier(len(keys))

            def worker(item):
                conn = http.client.HTTPConnection("127.0.0.1", target.port, timeout=10)
                body = json.dumps({"pin": target.pin, "name": label, "publicKey": item})
                try:
                    conn.connect()
                    barrier.wait()
                    conn.request("POST", "/api/request", body,
                                 {"Content-Type": "application/json"})
                    response = conn.getresponse()
                    results.append((response.status, json.loads(response.read().decode("utf-8"))))
                except Exception as error:
                    results.append(("ERR", str(error)))
                finally:
                    conn.close()

            threads = [threading.Thread(target=worker, args=(item,)) for item in keys]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            return results

        race_runs = []
        for _ in range(10):
            race = Server()
            servers.append(race)
            keys = [race.key("race-a"), race.key("race-b")]
            results = post_concurrently(race, keys, "race")
            present = sum(1 for item in keys if item.split()[1] in race.keys())
            race_runs.append((results, present))

        check("one request wins in 10 trials",
              all(sum(1 for status, _ in results if status == 200) == 1
                  for results, _ in race_runs), str(race_runs))
        check("one key is appended in 10 trials",
              all(present == 1 for _, present in race_runs), str(race_runs))

        once_runs = []
        for _ in range(10):
            once = Server(once=True)
            servers.append(once)
            keys = [once.key("once-a"), once.key("once-b")]
            results = post_concurrently(once, keys, "once")
            present = sum(1 for item in keys if item.split()[1] in once.keys())
            once_runs.append((results, present))

        def statuses(results):
            return sorted(status for status, _ in results if isinstance(status, int))

        check("once has one winner and one rejection in 10 trials",
              all(statuses(results) == [200, 401] for results, _ in once_runs),
              str(once_runs))
        check("once appends one key in 10 trials",
              all(present == 1 for _, present in once_runs), str(once_runs))

        limit = Server()
        servers.append(limit)
        limit_key = limit.key("limit")
        for _ in range(5):
            limit.post("000000", limit_key)
        status, body = limit.post("000000", limit_key)
        check("sixth wrong pin is 429", status == 429, "%s %s" % (status, body))
        status, body = limit.post(limit.pin, limit_key)
        check("rate limit blocks correct pin", status == 429, "%s %s" % (status, body))
    finally:
        for server in servers:
            server.stop()

    print("%d passed, %d failed" % (passed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

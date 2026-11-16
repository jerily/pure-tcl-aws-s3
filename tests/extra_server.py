from support import Fixture, run, verify_signature
import base64
import gzip
import hashlib
from urllib.parse import parse_qs, urlsplit, unquote
from xml.etree import ElementTree as ET


class Handler(Fixture):
    def route(self, body):
        assert verify_signature(self, body) == "s3"
        url = urlsplit(self.path)
        path = unquote(url.path)
        query = parse_qs(url.query, keep_blank_values=True)
        if self.command == "HEAD":
            self.reply(404 if "missing" in path else 403 if "forbidden" in path else 200, b"")
        elif self.command == "PUT":
            if path.endswith("/bucket/"):
                assert not body
            else:
                assert path == "/bucket/a/../雪 +%/😀" and body == "hello 😀".encode()
            self.reply(200, b"", {"ETag": '"tag"'})
        elif self.command == "DELETE":
            self.reply(204, b"")
        elif self.command == "POST":
            assert "delete" in query
            assert self.headers["Content-MD5"] == base64.b64encode(hashlib.md5(body).digest()).decode()
            document = ET.fromstring(body)
            keys = [e.text for e in document.findall("{*}Object/{*}Key")]
            assert keys == ["a&b", "雪"]
            self.reply(200, "<DeleteResult/>")
        elif path == "/":
            self.reply(200, "<ListAllMyBucketsResult><Buckets><Bucket><Name>bucket</Name></Bucket></Buckets></ListAllMyBucketsResult>")
        elif "list-type" in query:
            if "continuation-token" in query:
                assert query["continuation-token"] == ["next+/?"]
                result = "<Contents><Key>%E9%9B%AA</Key></Contents><IsTruncated>false</IsTruncated>"
            else:
                result = "<Contents><Key>a%2Bb</Key></Contents><IsTruncated>true</IsTruncated><NextContinuationToken>next+/?</NextContinuationToken>"
            self.reply(200, "<ListBucketResult><EncodingType>url</EncodingType>" + result + "</ListBucketResult>")
        elif path.endswith("/compressed"):
            self.reply(200, gzip.compress(b"stored bytes\x00\xff"), {"Content-Encoding": "gzip"})
        else:
            assert path == "/bucket/a/../雪 +%/😀"
            self.reply(200, bytes(range(256)))


if __name__ == "__main__":
    run(Handler, "extra.test")

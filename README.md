# pure-tcl-aws-s3

AWS S3 client implemented in Tcl 9.1. Its only package dependency is
[`pure-tcl-aws-core`](https://github.com/jerily/pure-tcl-aws-core), which supplies
HTTP, JSON, XML, credentials and signing. No AWS C++ SDK is required.

```tcl
package require pure-tcl-aws-s3 0.1.1
set client [::aws::s3::create {region us-east-1}]
try {
    puts [$client list_buckets]
} finally {
    $client destroy
}
```

`package require awss3 1.0.19` is also supported. Use one implementation
of the `awss3` package per interpreter. Existing namespace commands
(`::aws::s3::method $client ...`) and client methods share the same behavior.
Client destruction returns an empty result. Unknown methods and invalid arguments
raise Tcl errors. See the core README for credentials, configuration and retries.

## Methods

| Method | Arguments after the client handle |
| --- | --- |
| `ls` | `bucket ?prefix?` |
| `put_text` | `bucket key text` |
| `put` | `bucket key filename ?content_type?` |
| `get` | `bucket key ?filename?` |
| `delete` | `bucket key` |
| `batch_delete` | `bucket keys` |
| `exists` | `bucket key` |
| `exists_bucket` | `bucket` |
| `create_bucket` | `bucket` |
| `delete_bucket` | `bucket` |
| `list_buckets` | — |
| `generate_presigned_url` | `args` |
| `create_multipart_upload` | `bucket key ?content_type?` |
| `upload_part` | `bucket key upload_id number data` |
| `complete_multipart_upload` | `bucket key upload_id parts` |
| `abort_multipart_upload` | `bucket key upload_id` |
| `put_multipart` | `bucket key filename ?part_size?` |

Presigning accepts `?-method method? ?-expire seconds? bucket key`; the namespace
form places these switches before the client handle.

## Behavior

Object bytes are preserved, including `Content-Encoding: gzip`. Literal dot segments in keys are not normalized. `put` and `get` buffer one object; `put_multipart` buffers one part (8 MiB by default). File downloads append, matching the existing binding. Multipart completion checks XML errors even on HTTP 200. Missing objects return false from `exists`; permission failures raise errors. Presigned URLs support temporary credentials and a maximum lifetime of seven days. General-purpose buckets are supported; S3 Express, access-point ARNs, SigV4a and automatic region redirects are outside this release.

## Install and examples

Install the core and its dependencies first, then run:

```sh
make install PREFIX=/your/prefix
```

The release recipe declares examples with `file` entries. After registry installation:

```sh
ttrek run -package pure-tcl-aws-s3 -script example-list-buckets
ttrek run -package pure-tcl-aws-s3 -script example-list-objects -- bucket ?prefix?
ttrek run -package pure-tcl-aws-s3 -script example-presign -- bucket key
```

`./run-example.sh --help` lists arguments. Set AWS credentials and `AWS_REGION`
or `AWS_DEFAULT_REGION` before running AWS examples. Examples read resources or sign URLs.

## Tests

With Tcl 9.1 and the dependencies on `TCLLIBPATH`:

```sh
make test TCLSH=tclsh9.1
```

Python 3 supplies local HTTP fixtures. Tests use fake credentials and do not
contact AWS. They check requests, result formats, and error handling.

## Install with ttrek

If you do not have the ttrek client, get it from [ttrek.sh](https://ttrek.sh).
Then install the package:

```sh
ttrek install pure-tcl-aws-s3
```

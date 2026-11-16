# 
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
# 

package require pure-tcl-aws-core 0.1.0
namespace eval ::aws::s3 {namespace path ::aws::core}
::aws::core::register s3 {ls put_text put get delete batch_delete exists create_bucket delete_bucket exists_bucket list_buckets generate_presigned_url put_multipart create_multipart_upload upload_part complete_multipart_upload abort_multipart_upload}

# Build a bucket/object URL without normalizing object-key path segments.
proc ::aws::s3::url {client {bucket {}} {key {}}} {
    set cfg [$client awsconfig]
    set endpoint [dict get $cfg endpoint]
    set p [urlparts $endpoint]
    if {[dict get $p query] ne {}} {error "S3 endpoint must not contain a query string"}
    if {$bucket eq {}} {return [string trimright $endpoint /]/}
    if {![regexp {^[A-Za-z0-9][A-Za-z0-9.-]*$} $bucket]} {error "invalid bucket name"}
    set path [string trimright [dict get $p path] /]
    set host [dict get $p authority]
    if {[dict get $cfg force_path_style] || [dict get $cfg custom_endpoint] || [string first . $bucket] >= 0} {
        append path /[uri $bucket]
    } else {set host $bucket.$host}
    append path /[uri $key 1]
    return [dict get $p scheme]://$host$path
}

# Send a signed S3 request and inspect XML errors even on HTTP 200.
proc ::aws::s3::call {client method bucket key {params {}} {body {}} {headers {}} {retry 0} {check_xml 0}} {
    set url [url $client $bucket $key]
    if {[llength $params]} {append url ?[querystring $params]}
    set response [$client awsrequest $method $url $headers $body $retry]
    if {$check_xml && [dict get $response body] ne {}} {
        set doc [xml [dict get $response body]]
        try {
            set root [$doc documentElement]
            if {[lindex [split [$root nodeName] :] end] eq "Error"} {aws_error s3 [xget $root Code Unknown] [xget $root Message {S3 operation failed}]}
        } finally {$doc delete}
    }
    return $response
}

# Decode a percent-encoded key returned by an S3 list response.
proc ::aws::s3::decode_key {value} {
    set bytes [binary format a* {}]
    for {set i 0} {$i < [string length $value]} {incr i} {
        set char [string index $value $i]
        if {$char eq "%"} {
            set hex [string range $value $i+1 $i+2]
            if {![regexp {^[0-9A-Fa-f]{2}$} $hex]} {error "invalid encoded S3 key"}
            append bytes [binary format H2 $hex]; incr i 2
        } else {append bytes [encoding convertto utf-8 $char]}
    }
    encoding convertfrom utf-8 $bytes
}

# List all matching keys using continuation tokens.
proc ::aws::s3::_ls {client bucket {prefix {}}} {
    set fields [list list-type 2 encoding-type url prefix $prefix]; set result {}; set seen {}
    while {1} {
        set response [call $client GET $bucket {} $fields {} {} 1 1]
        set doc [xml [dict get $response body]]
        try {
            set root [$doc documentElement]
            foreach node [nodes $root Contents] {
                set key [xget $node Key]
                if {[xget $root EncodingType] eq "url"} {set key [decode_key $key]}
                lappend result $key
            }
            if {![boolean [xget $root IsTruncated false]]} {return $result}
            set token [xget $root NextContinuationToken]
            if {$token eq {}} {error "truncated S3 response is missing a continuation token"}
            next seen $token
            set fields [list list-type 2 encoding-type url prefix $prefix continuation-token $token]
        } finally {$doc delete}
    }
}

# Upload UTF-8 text as an object.
proc ::aws::s3::_put_text {client bucket key text} {
    call $client PUT $bucket $key {} [encoding convertto utf-8 $text] {Content-Type text/plain} 1
    return
}

# Upload a binary file in one request; use put_multipart for large files.
proc ::aws::s3::_put {client bucket key filename {content_type application/octet-stream}} {
    call $client PUT $bucket $key {} [readfile $filename] [dict create Content-Type $content_type] 1
    return
}

# Return raw object bytes or append them to the requested binary file.
proc ::aws::s3::_get {client bucket key {filename {}}} {
    set response [call $client GET $bucket $key {} {} {} 1]
    set bytes [dict get $response body]
    if {$filename eq {}} {return $bytes}
    set channel [open $filename ab]
    try {puts -nonewline $channel $bytes} finally {close $channel}
    return
}

# Delete a single object.
proc ::aws::s3::_delete {client bucket key} {call $client DELETE $bucket $key {} {} {} 1; return}

# Delete objects in batches and report per-object failures.
proc ::aws::s3::_batch_delete {client bucket keys} {
    for {set start 0} {$start < [llength $keys]} {incr start 1000} {
        set body {<Delete xmlns="http://s3.amazonaws.com/doc/2006-03-01/">}
        foreach key [lrange $keys $start $start+999] {append body <Object><Key>[escape_xml $key]</Key></Object>}
        append body </Delete>
        set bytes [encoding convertto utf-8 $body]
        set headers [dict create Content-Type application/xml Content-MD5 [binary encode base64 -maxlen 0 [::md5::md5 -- $bytes]]]
        set response [call $client POST $bucket {} {delete {}} $bytes $headers 1 1]
        set doc [xml [dict get $response body]]
        try {
            set errors {}
            foreach e [nodes [$doc documentElement] Error] {lappend errors [dict create key [xget $e Key] code [xget $e Code] message [xget $e Message]]}
            if {[llength $errors]} {aws_error s3 BatchFailure "object deletions failed: $errors"}
        } finally {$doc delete}
    }
    return
}

# Treat only missing resources as false; authorization failures remain errors.
proc ::aws::s3::head_exists {client bucket key} {
    try {call $client HEAD $bucket $key {} {} {} 1; return 1} on error {message opts} {
        if {[lindex [dict get $opts -errorcode] 2] in {HTTP404 NotFound NoSuchKey NoSuchBucket}} {return 0}
        return -options $opts $message
    }
}

# Check whether an object exists.
proc ::aws::s3::_exists {client bucket key} {head_exists $client $bucket $key}

# Check whether a bucket exists and is accessible.
proc ::aws::s3::_exists_bucket {client bucket} {head_exists $client $bucket {}}

# Create a bucket with the required regional location constraint.
proc ::aws::s3::_create_bucket {client bucket} {
    set region [dict get [$client awsconfig] region]; set body {}
    if {$region ne "us-east-1"} {set body "<CreateBucketConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><LocationConstraint>[escape_xml $region]</LocationConstraint></CreateBucketConfiguration>"}
    call $client PUT $bucket {} {} [encoding convertto utf-8 $body] {Content-Type application/xml}
    return
}

# Delete an empty bucket.
proc ::aws::s3::_delete_bucket {client bucket} {call $client DELETE $bucket {}; return}

# List owned buckets, following the current API's continuation token.
proc ::aws::s3::_list_buckets {client} {
    set result {}; set params {}; set seen {}
    while {1} {
        set doc [xml [dict get [call $client GET {} {} $params {} {} 1 1] body]]
        try {
            set root [$doc documentElement]
            lappend result {*}[xlist $root Buckets/Bucket/Name]
            set token [xget $root ContinuationToken]
            if {![next seen $token]} {return $result}
            set params [list continuation-token $token]
        } finally {$doc delete}
    }
}

# Parse the original presigning switches before positional arguments.
proc ::aws::s3::presign_options {args} {
    set method GET; set expire 3600
    while {[llength $args] && [string match -* [lindex $args 0]]} {
        if {[llength $args] < 2} {error "missing presigning option value"}
        lassign $args option value
        switch -- $option {
            -method {set method [string toupper $value]}
            -expire {set expire [integer $value 1 604800 expiration]}
            default {error "unknown option: $option"}
        }
        set args [lrange $args 2 end]
    }
    if {$method ni {GET HEAD PUT POST DELETE PATCH}} {error "invalid presigned HTTP method"}
    return [list $method $expire $args]
}

# Presign an object URL using the client's current credentials.
proc ::aws::s3::_generate_presigned_url {client args} {
    lassign [presign_options {*}$args] method expire positional
    if {[llength $positional] != 2} {error "wrong # args: should be \"$client generate_presigned_url ?-method method? ?-expire seconds? bucket key\""}
    lassign $positional bucket key
    presign $method [url $client $bucket $key] [dict get [$client awsconfig] region] s3 [$client awscredentials] $expire
}

# Preserve the namespace command's switches-before-handle calling convention.
proc ::aws::s3::generate_presigned_url {args} {
    lassign [presign_options {*}$args] method expire positional
    if {[llength $positional] != 3} {error "wrong # args: should be \"generate_presigned_url ?-method method? ?-expire seconds? handle bucket key\""}
    lassign $positional handle bucket key
    client s3 $handle
    _generate_presigned_url $handle -method $method -expire $expire $bucket $key
}

# Initiate an upload and return its opaque upload ID.
proc ::aws::s3::_create_multipart_upload {client bucket key {content_type application/octet-stream}} {
    set doc [xml [dict get [call $client POST $bucket $key {uploads {}} {} [dict create Content-Type $content_type] 0 1] body]]
    try {return [xget [$doc documentElement] UploadId]} finally {$doc delete}
}

# Upload a numbered binary part and return its quoted ETag.
proc ::aws::s3::_upload_part {client bucket key upload_id number data} {
    integer $number 1 10000 part_number
    if {[string length $data] > 5368709120} {error "part exceeds 5 GiB"}
    set r [call $client PUT $bucket $key [list partNumber $number uploadId $upload_id] $data {Content-Type application/octet-stream} 1]
    return [required [dict get $r headers] etag]
}

# Complete an upload after sorting and validating its part/ETag pairs.
proc ::aws::s3::_complete_multipart_upload {client bucket key upload_id parts} {
    if {![llength $parts]} {error "parts must not be empty"}
    set seen {}
    foreach part $parts {
        if {[llength $part] != 2} {error "each part must be a part_number/etag pair"}
        lassign $part number etag
        integer $number 1 10000 part_number
        if {$number in $seen || $etag eq {}} {error "duplicate part number or empty ETag"}
        lappend seen $number
    }
    set body {<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">}
    foreach part [lsort -integer -index 0 $parts] {lassign $part number etag; append body <Part><PartNumber>$number</PartNumber><ETag>[escape_xml $etag]</ETag></Part>}
    append body </CompleteMultipartUpload>
    set r [call $client POST $bucket $key [list uploadId $upload_id] [encoding convertto utf-8 $body] {Content-Type application/xml} 0 1]
    set doc [xml [dict get $r body]]
    try {return [xget [$doc documentElement] ETag]} finally {$doc delete}
}

# Abort an unfinished multipart upload.
proc ::aws::s3::_abort_multipart_upload {client bucket key upload_id} {
    call $client DELETE $bucket $key [list uploadId $upload_id] {} {} 1
    return
}

# Upload one file part at a time and abort on read, upload or completion failure.
proc ::aws::s3::_put_multipart {client bucket key filename {part_size 8388608}} {
    integer $part_size 5242880 5368709120 part_size
    if {[catch {open $filename rb} channel]} {error "Error unable to read file"}
    set upload_id {}
    try {
        seek $channel 0 end; set size [tell $channel]; seek $channel 0
        if {($size+$part_size-1)/$part_size > 10000} {error "file requires more than 10000 parts; increase part_size"}
        if {$size == 0} {
            set result [call $client PUT $bucket $key {} [binary format a* {}] {Content-Type application/octet-stream} 1]
            return [::aws::core::get [dict get $result headers] etag]
        }
        set upload_id [_create_multipart_upload $client $bucket $key]
        set parts {}; set number 0
        for {set offset 0} {$offset < $size} {incr offset $length} {
            set length [expr {min($part_size,$size-$offset)}]
            set bytes [read $channel $length]
            if {[string length $bytes] != $length} {error "Error unable to read file during multipart upload"}
            lappend parts [list [incr number] [_upload_part $client $bucket $key $upload_id $number $bytes]]
        }
        return [_complete_multipart_upload $client $bucket $key $upload_id $parts]
    } on error {message opts} {
        if {$upload_id ne {} && [catch {_abort_multipart_upload $client $bucket $key $upload_id} abort]} {append message "; failed to abort multipart upload $upload_id: $abort"}
        return -options $opts $message
    } finally {close $channel}
}
package provide pure-tcl-aws-s3 0.1.0
package provide awss3 1.0.19

package com.demo.myapi

import input
import data.com.demo.common.jwt.valid_token

default allow := { #disallow requests by default
    "allowed": false,
    "reason": "unauthorized resource access"
}

allow := { "allowed": true } { #allow GET requests to viewer user
    input.method == "GET"
    input.path == "policy"
    token := valid_token(input.identity)
    token.name == "viewer"
    token.valid
}

allow := { "allowed": true } { #allow POST requests to admin user 
    input.method == "POST"
    input.path == "policy"
    token := valid_token(input.identity)
    token.name == "admin"
    token.valid
}
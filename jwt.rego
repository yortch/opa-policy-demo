package com.demo.common.jwt

import input
import future.keywords.in

valid_token(jwt) = token {
    [header, payload, sig]:= io.jwt.decode(jwt)

    valid := io.jwt.verify_hs256(jwt, "secret")
    token := {"valid": valid,
                "name": payload.name}
}
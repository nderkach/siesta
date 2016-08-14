//
//  RequestSpec.swift
//  Siesta
//
//  Created by Paul on 2016/8/14.
//  Copyright © 2016 Bust Out Solutions. All rights reserved.
//

import Siesta
import Quick
import Nimble
import Nocilla

class RequestSpec: ResourceSpecBase
    {
    override func resourceSpec(service: () -> Service, _ resource: () -> Resource)
        {
        context("Resource.request()")
            {
            it("initates a network call")
                {
                stubRequest(resource, "GET").andReturn(200)
                awaitNewData(resource().request(.GET))
                }

            it("handles various HTTP methods")
                {
                stubRequest(resource, "PATCH").andReturn(200)
                awaitNewData(resource().request(.PATCH))
                }

            it("sends headers from configuration")
                {
                service().configure { $0.config.headers["Zoogle"] = "frotz" }
                stubRequest(resource, "GET")
                    .withHeader("Zoogle", "frotz")
                    .andReturn(200)
                awaitNewData(resource().request(.GET))
                }

            describe("decorators")
                {
                it("are called for every request")
                    {
                    var beforeHookCount = 0
                    service().configure
                        {
                        $0.config.decorateRequests
                            {
                            res, req in
                            expect(res) === resource()
                            beforeHookCount += 1
                            return req
                            }
                        }

                    stubRequest(resource, "GET").andReturn(200)
                    stubRequest(resource, "POST").andReturn(200)
                    awaitNewData(resource().load())
                    awaitNewData(resource().request(.POST))

                    expect(beforeHookCount) == 2
                    }

                it("can attach request hooks")
                    {
                    var successHookCalled = false
                    service().configure
                        {
                        $0.config.decorateRequests
                            { $1.onSuccess { _ in successHookCalled = true } }
                        }

                    stubRequest(resource, "GET").andReturn(200)
                    awaitNewData(resource().load())

                    expect(successHookCalled) == true
                    }

                it("can preemptively cancel requests")
                    {
                    service().configure
                        {
                        $0.config.decorateRequests
                            {
                            $1.cancel()
                            return $1
                            }
                        }

                    awaitFailure(resource().load(), alreadyCompleted: true)  // Nocilla will flag if network call goes through
                    }

                describe("substituting a request")
                    {
                    let dummyRequest = { Resource.failedRequest(Error(userMessage: "dummy", cause: DummyError())) }
                    let dummyReq0 = specVar { dummyRequest() },
                        dummyReq1 = specVar { dummyRequest() }

                    it("causes outside observers to see the replacement")
                        {
                        service().configure
                            {
                            $0.config.decorateRequests
                                {
                                $1.cancel()
                                return dummyReq0()
                                }
                            }

                        let req = resource().load()
                        expect(req) === dummyReq0()
                        awaitFailure(req, alreadyCompleted: true)
                        }

                    it("causes downstream decorators to see the replacement")
                        {
                        service().configure
                            {
                            $0.config.decorateRequests
                                {
                                expect($0) == resource()
                                $1.cancel()
                                return dummyReq0()  // passed here
                                }
                            $0.config.decorateRequests
                                {
                                expect($1) === dummyReq0()  // seen here
                                return dummyReq1()
                                }
                            }

                        let req = resource().load()
                        expect(req) === dummyReq1()
                        awaitFailure(req, alreadyCompleted: true)
                        }

                    pending("starts the original request if it was wrapped") { }

                    it("does not start the original request it was discarded")
                        {
                        service().configure
                            {
                            $0.config.decorateRequests
                                { _ in dummyReq0() }
                            }
                        awaitFailure(resource().load(), alreadyCompleted: true)  // Nocilla will flag if network call goes through
                        }
                    }
                }
            }

        it("can be cancelled")
            {
            let reqStub = stubRequest(resource, "GET").andReturn(200).delay()
            let req = resource().request(.GET)
            req.onFailure
                { expect($0.cause is Error.Cause.RequestCancelled) == true }
            req.onCompletion
                { expect($0.response.isCancellation) == true }
            req.cancel()
            reqStub.go()
            awaitFailure(req, alreadyCompleted: true)
            }

        it(".cancel() has no effect if it already succeeded")
            {
            stubRequest(resource, "GET").andReturn(200)
            let req = resource().request(.GET)
            req.onCompletion
                { expect($0.response.isCancellation) == false }
            awaitNewData(req)
            req.cancel()
            awaitNewData(req, alreadyCompleted: true)
            }

        it(".cancel() has no effect if it never started")
            {
            let req = resource().request(.POST, json: ["unencodable": NSData()])
            req.onCompletion
                { expect($0.response.isCancellation) == false }
            awaitFailure(req, alreadyCompleted: true)
            req.cancel()
            }

        context("request body")
            {
            it("handles raw data")
                {
                let bytes: [UInt8] = [0x00, 0xFF, 0x17, 0xCA]
                let nsdata = NSData(bytes: bytes, length: bytes.count)

                stubRequest(resource, "POST")
                    .withHeader("Content-Type", "application/monkey")
                    .withBody(nsdata)
                    .andReturn(200)

                awaitNewData(resource().request(.POST, data: nsdata, contentType: "application/monkey"))
                }

            it("handles string data")
                {
                stubRequest(resource, "POST")
                    .withHeader("Content-Type", "text/plain; charset=utf-8")
                    .withBody("Très bien!")
                    .andReturn(200)

                awaitNewData(resource().request(.POST, text: "Très bien!"))
                }

            it("handles string encoding errors")
                {
                let req = resource().request(.POST, text: "Hélas!", encoding: NSASCIIStringEncoding)
                awaitFailure(req, alreadyCompleted: true)
                req.onFailure
                    {
                    let cause = $0.cause as? Error.Cause.UnencodableText
                    expect(cause?.encodingName) == "us-ascii"
                    expect(cause?.text) == "Hélas!"
                    }
                }

            it("handles JSON data")
                {
                stubRequest(resource, "PUT")
                    .withHeader("Content-Type", "application/json")
                    .withBody("{\"question\":[[2,\"be\"],[\"not\",2,\"be\"]]}")
                    .andReturn(200)

                awaitNewData(resource().request(.PUT, json: ["question": [[2, "be"], ["not", 2, "be"]]]))
                }

            it("handles JSON encoding errors")
                {
                let req = resource().request(.POST, json: ["question": [2, NSData()]])
                awaitFailure(req, alreadyCompleted: true)
                req.onFailure
                    { expect($0.cause is Error.Cause.InvalidJSONObject) == true }
                }

            context("with URL encoding")
                {
                it("encodes parameters")
                    {
                    stubRequest(resource, "PATCH")
                        .withHeader("Content-Type", "application/x-www-form-urlencoded")
                        .withBody("brown=cow&foo=bar&how=now")
                        .andReturn(200)

                    awaitNewData(resource().request(.PATCH, urlEncoded: ["foo": "bar", "how": "now", "brown": "cow"]))
                    }

                it("escapes unsafe characters")
                    {
                    stubRequest(resource, "PATCH")
                        .withHeader("Content-Type", "application/x-www-form-urlencoded")
                        .withBody("%E2%84%A5%3D%26=%E2%84%8C%E2%84%91%3D%26&f%E2%80%A2%E2%80%A2=b%20r")
                        .andReturn(200)

                    awaitNewData(resource().request(.PATCH, urlEncoded: ["f••": "b r", "℥=&": "ℌℑ=&"]))
                    }

                it("give request failure for unencodable strings")
                    {
                    let bogus = String(
                        bytes: [0xD8, 0x00] as [UInt8],  // Unpaired surrogate char in UTF-16
                        encoding: NSUTF16BigEndianStringEncoding)!

                    for badParams in [[bogus: "foo"], ["foo": bogus]]
                        {
                        let req = resource().request(.PATCH, urlEncoded: badParams)
                        awaitFailure(req, alreadyCompleted: true)
                        req.onFailure
                            {
                            let cause = $0.cause as? Error.Cause.NotURLEncodable
                            expect(cause?.offendingString) == bogus
                            }
                        }
                    }
                }
            }
        }
    }

// MARK: - Helpers

private struct DummyError: ErrorType { }

import Foundation
import Testing
@testable import AnvilCore

#if os(macOS)
@Suite("OpenAIGateway")
struct OpenAIGatewayTests {
    @Test
    func routesRegisteredModelsAndDefaultModelToText() async {
        let gateway = OpenAIGateway()
        let endpoint = URL(string: "http://127.0.0.1:8101")!
        await gateway.register(modelID: "org/model", endpoint: endpoint)

        #expect(await gateway.hasRoute(for: "org/model"))
        #expect(await gateway.hasRoute(for: "default_model"))
        #expect(!(await gateway.hasRoute(for: "missing")))
    }

    @Test
    func keepsImageAndTextRoutesSeparate() async {
        let gateway = OpenAIGateway()
        await gateway.register(
            modelID: "flux",
            endpoint: URL(string: "http://127.0.0.1:8201")!,
            kind: .image
        )

        #expect(await gateway.hasRoute(for: "flux", kind: .image))
        #expect(!(await gateway.hasRoute(for: "flux", kind: .text)))
        #expect(await gateway.hasRoute(for: "default_model", kind: .image))
        #expect(!(await gateway.hasRoute(for: "default_model", kind: .text)))
    }
}
#endif

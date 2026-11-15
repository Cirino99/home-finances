import SwiftUI

/// Componenti di terze parti incluse nell'app e le loro licenze (§ 3), che chiedono di riportare
/// l'avviso di copyright anche nella versione compilata.
struct LicensesView: View {
    var body: some View {
        Form {
            Section {
                ForEach(ThirdPartyComponent.all) { component in
                    NavigationLink {
                        LicenseTextView(component: component)
                    } label: {
                        LabeledContent(component.name, value: component.licenseName)
                    }
                }
            } footer: {
                Text("Home Finances usa queste componenti open source.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Licenze")
    }
}

private struct LicenseTextView: View {
    let component: ThirdPartyComponent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(component.purpose)
                    .foregroundStyle(.secondary)
                Text(component.licenseText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(component.name)
    }
}

struct ThirdPartyComponent: Identifiable, Sendable {
    let name: String
    let purpose: LocalizedStringResource
    let licenseName: String
    /// Testo originale, in inglese: non si traduce.
    let licenseText: String

    var id: String { name }

    static let all = [sqlCipher, grdb]

    /// Da `LICENSE.md` del pacchetto `SQLCipher.swift` 4.20.0.
    static let sqlCipher = ThirdPartyComponent(
        name: "SQLCipher",
        purpose: "Cifra il database sul dispositivo.",
        licenseName: "BSD",
        licenseText: """
            Community Edition Open Source License

            Copyright (c) 2025, ZETETIC LLC
            All rights reserved.

            Redistribution and use in source and binary forms, with or without \
            modification, are permitted provided that the following conditions are met:
                * Redistributions of source code must retain the above copyright \
            notice, this list of conditions and the following disclaimer.
                * Redistributions in binary form must reproduce the above copyright \
            notice, this list of conditions and the following disclaimer in the \
            documentation and/or other materials provided with the distribution.
                * Neither the name of the ZETETIC LLC nor the \
            names of its contributors may be used to endorse or promote products \
            derived from this software without specific prior written permission.

            THIS SOFTWARE IS PROVIDED BY ZETETIC LLC ''AS IS'' AND ANY \
            EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED \
            WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE \
            DISCLAIMED. IN NO EVENT SHALL ZETETIC LLC BE LIABLE FOR ANY \
            DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES \
            (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; \
            LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND \
            ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT \
            (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS \
            SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

            SQLCipher is based on SQLite, whose source code is in the public domain.
            """
    )

    /// Da `LICENSE` del fork `sqlcipher/GRDB.swift` 7.12.0.
    static let grdb = ThirdPartyComponent(
        name: "GRDB.swift",
        purpose: "Accesso al database.",
        licenseName: "MIT",
        licenseText: """
            Copyright (C) 2015-2025 Gwendal Roué

            Permission is hereby granted, free of charge, to any person obtaining a copy of this software \
            and associated documentation files (the "Software"), to deal in the Software without restriction, \
            including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, \
            and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, \
            subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all copies or substantial \
            portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT \
            LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. \
            IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, \
            WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE \
            SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
            """
    )
}

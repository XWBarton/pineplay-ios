import SwiftUI

struct ServerSetupView: View {
    @EnvironmentObject var api: PinepodsAPIService

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // Logo area
                    VStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)

                        Text("PinePlay")
                            .font(.largeTitle.bold())

                        Text("Connect to your podcast server")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 48)

                    // Form
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Server URL")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("https://podcasts.example.com", text: $serverURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .padding()
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Username")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("Username", text: $username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding()
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            SecureField("Password", text: $password)
                                .padding()
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.horizontal)

                    if let error = errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button {
                        Task { await connect() }
                    } label: {
                        Group {
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Connect")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    .disabled(isLoading || serverURL.isEmpty || username.isEmpty || password.isEmpty)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func connect() async {
        isLoading = true
        errorMessage = nil
        do {
            try await api.login(serverURL: serverURL, username: username, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

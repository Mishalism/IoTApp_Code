import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'DashboardScreen.dart';

class LoginSignupPage extends StatefulWidget {
  const LoginSignupPage({super.key});

  @override
  State<LoginSignupPage> createState() => _LoginSignupPageState();
}

class _LoginSignupPageState extends State<LoginSignupPage> {
  final FirebaseAuth auth = FirebaseAuth.instance;

  final email = TextEditingController(); 
  final password = TextEditingController();
  final confirmPassword = TextEditingController();
  final name = TextEditingController();

  bool isLogin = true;
  bool loading = false;
  String errorMessage = "";

  void showMessage(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> handleAuth() async {
    if (!isLogin) {
      if (name.text.trim().isEmpty) {
        setState(() => errorMessage = "Please enter your name.");
        return;
      }
      if (password.text != confirmPassword.text) {
        setState(() => errorMessage = "Passwords do not match.");
        return;
      }
    }

    setState(() {
      loading = true;
      errorMessage = "";
    });

    try {
      isLogin ? await loginUser() : await signUpUser();
    } on FirebaseAuthException catch (e) {
      setState(() => errorMessage = e.message ?? "Something went wrong");
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> loginUser() async {
    UserCredential user = await auth.signInWithEmailAndPassword(
      email: email.text.trim(),
      password: password.text.trim(),
    );

    if (!user.user!.emailVerified) {
      await auth.signOut();
      setState(() => errorMessage = "Please verify your email first.");
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => DashboardScreen()),
    );
  }

  Future<void> signUpUser() async {
    UserCredential user = await auth.createUserWithEmailAndPassword(
      email: email.text.trim(),
      password: password.text.trim(),
    );

    await user.user!.updateDisplayName(name.text.trim());
    await user.user!.sendEmailVerification();

    showMessage("Verification email sent. Please check your inbox.");
    setState(() => isLogin = true);
  }

  Future<void> resendVerificationEmail() async {
    if (email.text.isEmpty || password.text.isEmpty) {
      showMessage("Enter email & password to resend verification.");
      return;
    }

    try {
      UserCredential user = await auth.signInWithEmailAndPassword(
        email: email.text.trim(),
        password: password.text.trim(),
      );

      if (!user.user!.emailVerified) {
        await user.user!.sendEmailVerification();
        showMessage("Verification email resent. Check inbox & spam.");
        await auth.signOut();
      } else {
        showMessage("Email is already verified.");
      }
    } on FirebaseAuthException catch (e) {
      showMessage(e.message ?? "Error resending email.");
    }
  }

  Future<void> forgotPassword() async {
    if (email.text.isEmpty) {
      showMessage("Enter your email first.");
      return;
    }

    try {
      await auth.sendPasswordResetEmail(email: email.text.trim());
      showMessage("Password reset email sent. Check inbox & spam.");
    } on FirebaseAuthException catch (e) {
      showMessage(e.message ?? "Error sending reset email.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.light(useMaterial3: true),
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1E3A8A), Color(0xFF3B82F6)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 450),
                child: Card(
                  elevation: 10,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18)),
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset("assets/logo2.png", height: 120),
                        const SizedBox(height: 14),

                        Text(
                          isLogin ? "Welcome Back" : "Create Your Account",
                          style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1E3A8A)),
                        ),

                        const SizedBox(height: 14),

                        // Error Box
                        if (errorMessage.isNotEmpty)
                          Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border:
                                      Border.all(color: Colors.red.shade300),
                                ),
                                child: Text(
                                  errorMessage,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: Colors.red,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                              if (errorMessage ==
                                  "Please verify your email first.")
                                TextButton(
                                  onPressed: loading
                                      ? null
                                      : resendVerificationEmail,
                                  child: const Text(
                                    "Resend Verification Email",
                                    style: TextStyle(
                                        color: Colors.blue,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                            ],
                          ),

                        // FULL NAME (signup only)
                        if (!isLogin) ...[
                          const SizedBox(height: 16),
                          TextField(
                            controller: name,
                            decoration: InputDecoration(
                              labelText: "Full Name",
                              prefixIcon: const Icon(Icons.person),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ],

                        const SizedBox(height: 16),

                        // EMAIL
                        TextField(
                          controller: email,
                          keyboardType: TextInputType.emailAddress,
                          decoration: InputDecoration(
                            labelText: "Email",
                            prefixIcon: const Icon(Icons.email),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),

                        const SizedBox(height: 16),

                        // PASSWORD
                        TextField(
                          controller: password,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: "Password",
                            prefixIcon: const Icon(Icons.lock),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),

                        // CONFIRM PASSWORD (after password)
                        if (!isLogin) ...[
                          const SizedBox(height: 16),
                          TextField(
                            controller: confirmPassword,
                            obscureText: true,
                            decoration: InputDecoration(
                              labelText: "Confirm Password",
                              prefixIcon: const Icon(Icons.lock),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ],

                        if (isLogin)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: loading ? null : forgotPassword,
                              child: const Text(
                                "Forgot Password?",
                                style: TextStyle(
                                  color: Colors.blue,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),

                        const SizedBox(height: 24),

                        // MAIN BUTTON
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: loading ? null : handleAuth,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1E3A8A),
                              foregroundColor: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: loading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(isLogin ? "Sign In" : "Sign Up"),
                          ),
                        ),

                        TextButton(
                          onPressed: () {
                            setState(() {
                              isLogin = !isLogin;
                              errorMessage = "";
                            });
                          },
                          child: Text(
                            isLogin
                                ? "Don't have an account? Sign Up"
                                : "Already have an account? Sign In",
                            style: const TextStyle(
                                color: Color(0xFF1E3A8A),
                                fontWeight: FontWeight.w600),
                          ),
                        )
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

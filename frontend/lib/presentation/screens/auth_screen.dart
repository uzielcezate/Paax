import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/auth_controller.dart';
import 'main_wrapper.dart';
import '../../core/theme/app_colors.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isLogin = true;
  final _formKey = GlobalKey<FormState>();
  
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SingleChildScrollView(
        child: Container(
          height: MediaQuery.of(context).size.height,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.music_note_rounded, size: 80, color: AppColors.primaryStart),
                const SizedBox(height: 32),
                Text(
                  _isLogin ? "Welcome Back" : "Create Account",
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _isLogin ? "Sign in to continue" : "Join Beaty today",
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 48),
                
                if (!_isLogin) 
                  _buildTextField("Full Name", _nameController, Icons.person_outline),
                if (!_isLogin) 
                  const SizedBox(height: 16),
                  
                _buildTextField("Email", _emailController, Icons.email_outlined),
                const SizedBox(height: 16),
                _buildTextField("Password", _passwordController, Icons.lock_outline, isPassword: true),
                
                if (_isLogin) ...[
                   const SizedBox(height: 8),
                   const Text("Demo account: user@gmail.com / 12345", 
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                   ),
                ],

                const SizedBox(height: 32),
                
                ElevatedButton(
                  onPressed: _isLoading ? null : _submit,
                  style: ElevatedButton.styleFrom(
                     padding: EdgeInsets.zero,
                     shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(56))
                  ),
                  child: Ink(
                      decoration: BoxDecoration(
                        gradient: AppColors.primaryGradient,
                        borderRadius: BorderRadius.circular(56),
                      ),
                      child: Container(
                        alignment: Alignment.center,
                        height: 56,
                        child: _isLoading 
                           ? const CircularProgressIndicator(color: Colors.white) 
                           : Text(_isLogin ? "Sign In" : "Sign Up"),
                      ),
                  )
                ),
                
                const SizedBox(height: 24),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isLogin = !_isLogin;
                    });
                  },
                  child: Text(
                    _isLogin ? "Don't have an account? Sign Up" : "Already have an account? Sign In",
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildTextField(String label, TextEditingController controller, IconData icon, {bool isPassword = false}) {
    return TextFormField(
      controller: controller,
      obscureText: isPassword,
      style: const TextStyle(color: Colors.white),
      validator: (value) => value == null || value.isEmpty ? "Required" : null,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.surfaceLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        labelStyle: TextStyle(color: AppColors.textSecondary),
      ),
    );
  }
  
  Future<void> _submit() async {
    if (_formKey.currentState!.validate()) {
      setState(() => _isLoading = true);
      
      final auth = context.read<AuthController>();
      try {
        if (_isLogin) {
          await auth.login(_emailController.text, _passwordController.text);
        } else {
          await auth.signup(_nameController.text, _emailController.text, _passwordController.text);
        }
        
        setState(() => _isLoading = false);
        
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => MainWrapper(key: MainWrapper.shellKey)),
          );
        }
      } catch (e) {
        if (mounted) setState(() => _isLoading = false);
        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceAll("Exception: ", ""))));
        }
      }
    }
  }
}

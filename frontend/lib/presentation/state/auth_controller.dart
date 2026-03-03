import 'package:flutter/material.dart';
import '../../data/local/hive_storage.dart';
import '../../domain/entities/user_profile.dart';

class AuthController extends ChangeNotifier {
  UserProfile? _currentUser;
  
  UserProfile? get currentUser => _currentUser;
  bool get isAuthenticated => _currentUser != null;
  bool get onboardingCompleted => HiveStorage.onboardingCompleted;

  AuthController() {
    _loadUser();
  }
  
  void _loadUser() {
    _currentUser = HiveStorage.getUserProfile();
    notifyListeners();
  }
  
  Future<void> login(String email, String password) async {
    // Demo User Logic
    if (email == 'user@gmail.com' && password == '12345') {
       final profile = UserProfile(name: "Uziel", email: email);
       await HiveStorage.saveUserProfile(profile);
       _loadUser();
    } else {
       throw Exception("Invalid demo credentials");
    }
  }
  
  Future<void> signup(String name, String email, String password) async {
    // For demo purposes, we will still allow signup
    final profile = UserProfile(name: name, email: email);
    await HiveStorage.saveUserProfile(profile);
    _loadUser();
  }
  
  Future<void> completeOnboarding() async {
    await HiveStorage.setOnboardingCompleted(true);
    notifyListeners();
  }
  
  Future<void> logout() async {
    await HiveStorage.clearAll(); // Clears user info too
    _loadUser();
  }
}

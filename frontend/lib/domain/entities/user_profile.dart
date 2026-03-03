import 'package:hive/hive.dart';

part 'user_profile.g.dart';

@HiveType(typeId: 3)
class UserProfile extends HiveObject {
  @HiveField(0)
  final String name;

  @HiveField(1)
  final String email;
  
  @HiveField(2)
  double minutesListened; // Using double for flexibility, though int seconds is fine

  UserProfile({
    required this.name,
    required this.email,
    this.minutesListened = 0.0,
  });
}

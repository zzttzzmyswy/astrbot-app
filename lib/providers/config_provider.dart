// lib/providers/config_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/config_service.dart';

final configServiceProvider = Provider<ConfigService>((ref) {
  return ConfigService();
});

final configInitializedProvider = FutureProvider<bool>((ref) async {
  final service = ref.read(configServiceProvider);
  await service.init();
  return service.isConfigured;
});

final isConfiguredProvider = Provider<bool>((ref) {
  final async = ref.watch(configInitializedProvider);
  return async.valueOrNull ?? false;
});

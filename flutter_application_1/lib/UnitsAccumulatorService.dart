import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:firebase_database/firebase_database.dart';

/// Runs the units (kWh) accumulator + live graph point recording as a
/// persistent, app-wide singleton.
///
/// The service:
/// 1. Reads appliance voltage/current/isOn values from Firebase.
/// 2. Calculates appliance power using:
///       Power = Voltage × Current × Power Factor
/// 3. Synchronizes the calculated power back to:
///       appliances/<appliance>/power
/// 4. Uses that power to calculate consumed kWh.
/// 5. Stores daily/monthly consumption.
/// 6. Stores power-history points for graphs.
///
/// IMPORTANT:
/// The Firebase listener only READS appliance data.
/// Power is written back from _tick(), not from _onApplianceData(),
/// preventing a Firebase listener -> write -> listener feedback loop.
class UnitsAccumulatorService extends ChangeNotifier {
  static final UnitsAccumulatorService _instance =
      UnitsAccumulatorService._internal();

  factory UnitsAccumulatorService() => _instance;

  UnitsAccumulatorService._internal();

  // ============================================================
  // PUBLIC STATE
  // ============================================================

  double totalVoltage = 220.0;
  double totalCurrent = 0.0;
  double totalPower = 0.0;

  double totalUnitsToday = 0.0;
  double totalUnitsThisMonth = 0.0;

  Map<String, Map<String, dynamic>> applianceBreakdown = {};

  bool consumptionLoaded = false;

  // ============================================================
  // POWER FACTORS
  // ============================================================

  /// Assumed power factors because the current hardware setup
  /// measures voltage/current but does not directly measure phase angle.
  ///
  /// Real electrical power would ideally require a power/energy meter
  /// capable of measuring the phase relationship between voltage and
  /// current.
  static const Map<String, double> assumedPowerFactor = {
    "Fan": 0.70,
    "AC": 0.85,
    "Fridge": 0.80,
    "Light": 0.95,
    "TV": 0.90,
  };

  // ============================================================
  // INTERNAL
  // ============================================================

  bool _running = false;
  Timer? _unitsTimer;
  StreamSubscription<DatabaseEvent>? _applianceSub;

  final DatabaseReference appliancesRef =
      FirebaseDatabase.instance.ref("appliances");

  final DatabaseReference chartHistoryRef =
      FirebaseDatabase.instance.ref("power_history");

  final Map<String, DateTime> _lastUpdateTime = {};

  bool _accumulatorBusy = false;

  String? _loadedDayKey;
  String? _loadedMonthKey;

  // ============================================================
  // POWER SYNC SETTINGS
  // ============================================================

  /// Do not write tiny floating-point differences to Firebase.
  ///
  /// Example:
  /// Firebase = 1315.00 W
  /// New      = 1315.03 W
  ///
  /// Difference is too small, so no Firebase write is needed.
  static const double _powerSyncToleranceWatts = 1.0;

  // ============================================================
  // START / STOP
  // ============================================================

  /// Call once, for example from main.dart after Firebase.initializeApp().
  void start() {
    if (_running) return;

    _running = true;

    // Listen for appliance changes.
    //
    // IMPORTANT:
    // This listener READS data and updates local state.
    // It does NOT write power back to Firebase.
    _applianceSub = appliancesRef.onValue.listen(_onApplianceData);

    _loadConsumptionData();

    // Existing 3-second accumulator.
    _unitsTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _tick(),
    );

    debugPrint("UnitsAccumulatorService: STARTED");
  }

  /// Normally not needed because this service is intended to live
  /// for the lifetime of the application.
  void stop() {
    _unitsTimer?.cancel();
    _unitsTimer = null;

    _applianceSub?.cancel();
    _applianceSub = null;

    _running = false;

    debugPrint("UnitsAccumulatorService: STOPPED");
  }

  // ============================================================
  // VALUE PARSER
  // ============================================================

  double parseValue(dynamic value) {
    if (value == null) return 0.0;

    if (value is num) {
      return value.toDouble();
    }

    final s = value
        .toString()
        .replaceAll(RegExp(r'[^0-9.\-]'), '');

    return double.tryParse(s) ?? 0.0;
  }

  // ============================================================
  // DATE KEYS
  // ============================================================

  String todayKey() {
    final now = DateTime.now();

    return "${now.year}-"
        "${now.month.toString().padLeft(2, '0')}-"
        "${now.day.toString().padLeft(2, '0')}";
  }

  String monthKey() {
    final now = DateTime.now();

    return "${now.year}-"
        "${now.month.toString().padLeft(2, '0')}";
  }

  // ============================================================
  // FIREBASE APPLIANCE LISTENER
  // ============================================================

  void _onApplianceData(DatabaseEvent event) {
    if (!event.snapshot.exists || event.snapshot.value == null) {
      return;
    }

    if (event.snapshot.value is! Map) {
      return;
    }

    final data =
        Map<String, dynamic>.from(event.snapshot.value as Map);

    double currentSum = 0.0;
    double powerSum = 0.0;
    double voltageRead = 220.0;

    final breakdown = <String, Map<String, dynamic>>{};

    data.forEach((key, value) {
      // Ignore the hourly_power child if it exists under appliances.
      if (key == "hourly_power") return;

      if (value is! Map) return;

      final appliance =
          Map<String, dynamic>.from(value);

      final isOn = appliance["isOn"] == true;

      final appVoltage =
          parseValue(appliance["voltage"]);

      final appCurrent =
          parseValue(appliance["current"]);

      final existingFirebasePower =
          parseValue(appliance["power"]);

      final powerFactor =
          assumedPowerFactor[key] ?? 1.0;

      // --------------------------------------------------------
      // CALCULATE POWER
      // --------------------------------------------------------
      //
      // P = V × I × PF
      //
      // This is an estimated real power because the current
      // hardware does not directly measure phase angle.
      //
      final calculatedPower =
          (appVoltage > 0 && appCurrent > 0)
              ? appVoltage * appCurrent * powerFactor
              : 0.0;

      final appUnits =
          parseValue(appliance["units"]);

      if (appVoltage > 100) {
        voltageRead = appVoltage;
      }

      breakdown[key] = {
        "isOn": isOn,
        "voltage": appVoltage,
        "current": appCurrent,

        // Locally calculated power.
        "power": calculatedPower,

        // The value currently stored in Firebase.
        //
        // We keep this separately so _tick() can determine
        // whether Firebase needs updating.
        "firebasePower": existingFirebasePower,

        "units": appUnits,
        "powerFactor": powerFactor,
      };

      // Only ON appliances contribute to the current/power totals.
      if (isOn) {
        currentSum += appCurrent;
        powerSum += calculatedPower;
      }
    });

    totalVoltage = voltageRead;
    totalCurrent = currentSum;
    totalPower = powerSum;

    applianceBreakdown = breakdown;

    notifyListeners();

    debugPrint(
      "UnitsAccumulatorService: "
      "power updated locally = ${totalPower.toStringAsFixed(2)} W",
    );
  }

  // ============================================================
  // LOAD TODAY + MONTHLY CONSUMPTION
  // ============================================================

  Future<void> _loadConsumptionData() async {
    final dayKey = todayKey();
    final monthKeyVal = monthKey();

    try {
      final dailySnapshot = await FirebaseDatabase.instance
          .ref("daily_units/$dayKey/total")
          .get();

      final monthlySnapshot = await FirebaseDatabase.instance
          .ref("monthly_units/$monthKeyVal/total")
          .get();

      totalUnitsToday = dailySnapshot.exists
          ? parseValue(dailySnapshot.value)
          : 0.0;

      totalUnitsThisMonth = monthlySnapshot.exists
          ? parseValue(monthlySnapshot.value)
          : 0.0;

      _loadedDayKey = dayKey;
      _loadedMonthKey = monthKeyVal;

      consumptionLoaded = true;

      notifyListeners();

      debugPrint(
        "UnitsAccumulatorService: "
        "loaded today=$totalUnitsToday kWh, "
        "month=$totalUnitsThisMonth kWh",
      );
    } catch (e) {
      debugPrint(
        "UnitsAccumulatorService: "
        "ERROR loading consumption: $e",
      );
    }
  }

  // ============================================================
  // DAY / MONTH ROLLOVER
  // ============================================================

  Future<void> _checkDateChange() async {
    final currentDay = todayKey();
    final currentMonth = monthKey();

    // ----------------------------------------------------------
    // NEW DAY
    // ----------------------------------------------------------

    if (_loadedDayKey != null &&
        currentDay != _loadedDayKey) {
      _lastUpdateTime.clear();

      final dailyRef =
          FirebaseDatabase.instance.ref(
        "daily_units/$currentDay",
      );

      final totalSnapshot =
          await dailyRef.child("total").get();

      if (!totalSnapshot.exists) {
        await dailyRef.child("total").set(0.0);
      }

      totalUnitsToday = 0.0;
      _loadedDayKey = currentDay;

      notifyListeners();

      debugPrint(
        "UnitsAccumulatorService: "
        "new day -> $currentDay",
      );
    }

    // ----------------------------------------------------------
    // NEW MONTH
    // ----------------------------------------------------------

    if (_loadedMonthKey != null &&
        currentMonth != _loadedMonthKey) {
      _lastUpdateTime.clear();

      final monthlyRef =
          FirebaseDatabase.instance.ref(
        "monthly_units/$currentMonth",
      );

      final monthlySnapshot =
          await monthlyRef.child("total").get();

      if (!monthlySnapshot.exists) {
        await monthlyRef.child("total").set(0.0);
      }

      // Reset appliance cumulative units.
      //
      // Historical daily/monthly records are NOT deleted.
      final applianceSnapshot =
          await appliancesRef.get();

      if (applianceSnapshot.exists &&
          applianceSnapshot.value is Map) {
        final data =
            Map<String, dynamic>.from(
          applianceSnapshot.value as Map,
        );

        final resetWrites = <Future<void>>[];

        data.forEach((key, value) {
          if (key == "hourly_power") return;

          if (value is! Map) return;

          resetWrites.add(
            appliancesRef
                .child(key)
                .child("units")
                .set(0.0),
          );
        });

        if (resetWrites.isNotEmpty) {
          await Future.wait(resetWrites);
        }
      }

      totalUnitsThisMonth = 0.0;
      _loadedMonthKey = currentMonth;

      notifyListeners();

      debugPrint(
        "UnitsAccumulatorService: "
        "new month -> $currentMonth",
      );
    }
  }

  // ============================================================
  // SYNCHRONIZE CALCULATED POWER TO FIREBASE
  // ============================================================

  Future<void> _syncCalculatedPowerToFirebase() async {
    if (applianceBreakdown.isEmpty) {
      return;
    }

    final writes = <Future<void>>[];

    for (final entry in applianceBreakdown.entries) {
      final name = entry.key;
      final data = entry.value;

      final calculatedPower =
          parseValue(data["power"]);

      final firebasePower =
          parseValue(data["firebasePower"]);

      // --------------------------------------------------------
      // Do not write if the difference is insignificant.
      // --------------------------------------------------------

      if ((calculatedPower - firebasePower).abs() <
          _powerSyncToleranceWatts) {
        continue;
      }

      // --------------------------------------------------------
      // IMPORTANT:
      //
      // This write happens HERE, inside _tick().
      //
      // It does NOT happen inside _onApplianceData().
      //
      // Therefore:
      //
      // _onApplianceData()
      //      ↓
      // calculate power
      //
      // _tick()
      //      ↓
      // write power
      //
      // Firebase changes
      //      ↓
      // _onApplianceData()
      //      ↓
      // calculate same power
      //
      // Next tick sees almost no difference
      //      ↓
      // NO WRITE
      //
      // This prevents a continuous feedback loop.
      // --------------------------------------------------------

      writes.add(
        appliancesRef.child(name).update({
          "power": calculatedPower,
        }),
      );

      debugPrint(
        "UnitsAccumulatorService: "
        "syncing $name power -> "
        "${calculatedPower.toStringAsFixed(2)} W",
      );
    }

    if (writes.isNotEmpty) {
      await Future.wait(writes);
    }
  }

  // ============================================================
  // MAIN TICK
  // ============================================================

  Future<void> _tick() async {
    if (_accumulatorBusy) {
      return;
    }

    if (!consumptionLoaded) {
      debugPrint(
        "UnitsAccumulatorService: "
        "tick skipped, consumption not loaded yet",
      );

      return;
    }

    _accumulatorBusy = true;

    try {
      await _checkDateChange();

      final now = DateTime.now();

      final dayKey = todayKey();
      final monthKeyVal = monthKey();

      // --------------------------------------------------------
      // MAKE SURE DATE KEYS ARE STILL CORRECT
      // --------------------------------------------------------

      if (_loadedDayKey != dayKey ||
          _loadedMonthKey != monthKeyVal) {
        await _loadConsumptionData();
      }

      // --------------------------------------------------------
      // FIRST:
      // Synchronize calculated power to Firebase.
      //
      // This does NOT calculate units.
      // It only keeps appliances/<name>/power synchronized.
      // --------------------------------------------------------

      await _syncCalculatedPowerToFirebase();

      // --------------------------------------------------------
      // LOCAL TOTALS
      // --------------------------------------------------------

      double dailyTotal = totalUnitsToday;
      double monthlyTotal = totalUnitsThisMonth;

      double dailyDelta = 0.0;
      double monthlyDelta = 0.0;

      final writes = <Future<void>>[];

      // --------------------------------------------------------
      // PROCESS EACH APPLIANCE
      // --------------------------------------------------------

      for (final entry in applianceBreakdown.entries) {
        final name = entry.key;
        final data = entry.value;

        final isOn = data["isOn"] == true;

        final power =
            parseValue(data["power"]);

        // ------------------------------------------------------
        // APPLIANCE OFF
        // ------------------------------------------------------

        if (!isOn || power <= 0) {
          _lastUpdateTime.remove(name);
          continue;
        }

        // ------------------------------------------------------
        // FIRST MOMENT AFTER APPLIANCE TURNS ON
        // ------------------------------------------------------

        if (!_lastUpdateTime.containsKey(name)) {
          _lastUpdateTime[name] = now;

          debugPrint(
            "UnitsAccumulatorService: "
            "$name started accumulating from now",
          );

          continue;
        }

        // ------------------------------------------------------
        // CALCULATE ELAPSED TIME
        // ------------------------------------------------------

        final elapsed =
            now.difference(
          _lastUpdateTime[name]!,
        ).inSeconds;

        if (elapsed <= 0) {
          continue;
        }

        // ------------------------------------------------------
        // SAFETY CAP
        //
        // Prevents a huge fake consumption spike if the app
        // was paused/backgrounded for a long time.
        // ------------------------------------------------------

        final cappedElapsed =
            elapsed.clamp(0, 30);

        // ------------------------------------------------------
        // CONVERT POWER TO kWh
        //
        // W × seconds / 3,600,000 = kWh
        // ------------------------------------------------------

        final kWhAdded =
            (power * cappedElapsed) /
                3600000.0;

        if (kWhAdded <= 0) {
          continue;
        }

        // ------------------------------------------------------
        // UPDATE LOCAL APPLIANCE UNITS
        // ------------------------------------------------------

        final oldApplianceUnits =
            parseValue(data["units"]);

        final newApplianceUnits =
            oldApplianceUnits + kWhAdded;

        applianceBreakdown[name]!["units"] =
            newApplianceUnits;

        // ------------------------------------------------------
        // UPDATE LOCAL DAILY/MONTHLY TOTALS
        // ------------------------------------------------------

        dailyTotal += kWhAdded;
        monthlyTotal += kWhAdded;

        dailyDelta += kWhAdded;
        monthlyDelta += kWhAdded;

        // ------------------------------------------------------
        // WRITE APPLIANCE UNITS
        // ------------------------------------------------------

        writes.add(
          appliancesRef
              .child(name)
              .update({
            "units": newApplianceUnits,
          }),
        );

        // ------------------------------------------------------
        // DAILY APPLIANCE CONSUMPTION
        // ------------------------------------------------------

        writes.add(
          FirebaseDatabase.instance
              .ref(
            "daily_units/$dayKey/$name",
          )
              .runTransaction(
            (currentData) {
              return Transaction.success(
                parseValue(currentData) +
                    kWhAdded,
              );
            },
          ),
        );

        // ------------------------------------------------------
        // MONTHLY APPLIANCE CONSUMPTION
        // ------------------------------------------------------

        writes.add(
          FirebaseDatabase.instance
              .ref(
            "monthly_units/$monthKeyVal/$name",
          )
              .runTransaction(
            (currentData) {
              return Transaction.success(
                parseValue(currentData) +
                    kWhAdded,
              );
            },
          ),
        );

        // ------------------------------------------------------
        // UPDATE LAST TIME
        // ------------------------------------------------------

        _lastUpdateTime[name] = now;

        // ------------------------------------------------------
        // POWER HISTORY FOR GRAPH
        // ------------------------------------------------------

        writes.add(
          chartHistoryRef
              .child(dayKey)
              .child(name)
              .push()
              .set({
            "t": now.millisecondsSinceEpoch,
            "p": power,
          }),
        );

        debugPrint(
          "UnitsAccumulatorService: "
          "$name -> "
          "${kWhAdded.toStringAsFixed(8)} kWh "
          "added from "
          "$power W for "
          "$cappedElapsed seconds",
        );
      }

      // --------------------------------------------------------
      // EXECUTE APPLIANCE WRITES
      // --------------------------------------------------------

      if (writes.isNotEmpty) {
        await Future.wait(writes);
      }

      // --------------------------------------------------------
      // UPDATE DAILY TOTAL IN FIREBASE
      // --------------------------------------------------------

      if (dailyDelta > 0) {
        await FirebaseDatabase.instance
            .ref(
          "daily_units/$dayKey/total",
        )
            .runTransaction(
          (currentData) {
            return Transaction.success(
              parseValue(currentData) +
                  dailyDelta,
            );
          },
        );
      }

      // --------------------------------------------------------
      // UPDATE MONTHLY TOTAL IN FIREBASE
      // --------------------------------------------------------

      if (monthlyDelta > 0) {
        await FirebaseDatabase.instance
            .ref(
          "monthly_units/$monthKeyVal/total",
        )
            .runTransaction(
          (currentData) {
            return Transaction.success(
              parseValue(currentData) +
                  monthlyDelta,
            );
          },
        );
      }

      // --------------------------------------------------------
      // UPDATE LOCAL TOTALS
      // --------------------------------------------------------

      totalUnitsToday = dailyTotal;
      totalUnitsThisMonth = monthlyTotal;

      notifyListeners();

      debugPrint(
        "UnitsAccumulatorService: "
        "today=${totalUnitsToday.toStringAsFixed(6)} kWh | "
        "month=${totalUnitsThisMonth.toStringAsFixed(6)} kWh | "
        "power=${totalPower.toStringAsFixed(2)} W",
      );
    } catch (e, stackTrace) {
      debugPrint(
        "UnitsAccumulatorService: ERROR IN TICK: $e",
      );

      debugPrint(
        stackTrace.toString(),
      );
    } finally {
      _accumulatorBusy = false;
    }
  }
}

/// Global singleton instance.
///
/// Same pattern as ThemeManager.dart.
final unitsAccumulator = UnitsAccumulatorService();
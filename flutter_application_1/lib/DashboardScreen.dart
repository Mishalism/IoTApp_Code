import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:fl_chart/fl_chart.dart';
import 'AppDrawer.dart';
import 'NotificationScreen.dart';
import 'NotificationManager.dart';
import 'UnitsAccumulatorService.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {

  // ============================================================
  // LIVE READINGS / CONSUMPTION / PER-APPLIANCE DATA
  // ============================================================
  // These all now live in UnitsAccumulatorService (see
  // UnitsAccumulatorService.dart), which runs app-wide instead of being
  // tied to this screen's lifecycle — so units keep accumulating (and
  // the live graph keeps recording) even while you're on Control,
  // Settings, or any other screen. This screen just reads from the
  // global `unitsAccumulator` singleton and rebuilds via AnimatedBuilder
  // whenever it changes. See build() below.
  // ============================================================

  // ============================================================
  // SETTINGS
  // ============================================================

  double threshold = 200.0;
  double pricePerUnit = 50.0;

  // ============================================================
  // LIVE GRAPH
  // DO NOT CHANGE THIS SYSTEM
  // ============================================================

  final Map<String, List<Map<String, dynamic>>> _liveChartData = {};
  bool chartReady = false;
  String? _chartDayKey;
  late DatabaseReference chartHistoryRef;

  static const double _pxPerHour = 140.0;
  static const double _fullDaySeconds = 86400.0;

  final ScrollController _chartScrollController =
      ScrollController();

  bool _followLive = true;

  StreamSubscription<DatabaseEvent>? _chartSub;

  // ============================================================
  // FIREBASE
  // ============================================================

  String userName = "User";

  final user = FirebaseAuth.instance.currentUser;

  late DatabaseReference prefRef;

  // ============================================================
  // NOTIFICATIONS
  // ============================================================

  final NotificationManager notificationManager =
      NotificationManager();

  // ============================================================
  // INIT
  // ============================================================

  @override
  void initState() {
    super.initState();

    chartHistoryRef =
        FirebaseDatabase.instance.ref("power_history");

    // NOTE: units accumulation and appliance-data listening now happen
    // in UnitsAccumulatorService (started once, app-wide, in main.dart)
    // — not here. This screen only subscribes to the chart's own data
    // and rebuilds whenever unitsAccumulator notifies listeners (see
    // build()).

    _loadTodayChartData();

    _chartScrollController.addListener(() {
      if (!_chartScrollController.hasClients) return;

      final atEnd =
          _chartScrollController.offset >=
              _chartScrollController.position.maxScrollExtent - 5;

      if (_followLive != atEnd) {
        setState(() => _followLive = atEnd);
      }
    });

    notificationManager.fetchNotifications(() {
      if (mounted) setState(() {});
    });

    if (user != null) {
      prefRef = FirebaseDatabase.instance
          .ref("user_preferences/${user!.uid}");

      loadUserPreferences();
      fetchUserName();
    }
  }

  @override
  void dispose() {
    _chartSub?.cancel();
    _chartScrollController.dispose();
    super.dispose();
  }

  // ============================================================
  // VALUE PARSER
  // ============================================================

  double parseValue(dynamic value) {
    if (value == null) return 0.0;

    if (value is double) return value;

    if (value is int) {
      return value.toDouble();
    }

    if (value is num) {
      return value.toDouble();
    }

    final s = value
        .toString()
        .replaceAll(RegExp(r'[^0-9.]'), '');

    return double.tryParse(s) ?? 0.0;
  }

  // ============================================================
  // DATE KEYS
  // ============================================================

  String _todayKey() {
    final now = DateTime.now();

    return "${now.year}-"
        "${now.month.toString().padLeft(2, '0')}-"
        "${now.day.toString().padLeft(2, '0')}";
  }

  String _monthKey() {
    final now = DateTime.now();

    return "${now.year}-"
        "${now.month.toString().padLeft(2, '0')}";
  }

  // ============================================================
  // EXISTING GRAPH CODE
  // ============================================================

  void _scrollToLiveEdge({bool force = false}) {
    if (!_followLive && !force) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chartScrollController.hasClients) return;

      _chartScrollController.animateTo(
        _chartScrollController.position.maxScrollExtent,
        duration:
            const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  // Live listener instead of a one-time fetch — since chart points are now
  // written by UnitsAccumulatorService (which keeps running regardless of
  // whether this screen is mounted), a live listener means this screen
  // always shows the true, up-to-date history for today: both points
  // recorded while it was mounted AND anything recorded while the user
  // was on another screen.
  void _loadTodayChartData() {
    final dayKey = _todayKey();
    _chartDayKey = dayKey;

    _chartSub?.cancel();
    _chartSub = chartHistoryRef.child(dayKey).onValue.listen((event) {
      if (!mounted) return;
      if (!event.snapshot.exists || event.snapshot.value == null) return;

      final data =
          Map<String, dynamic>.from(event.snapshot.value as Map);

      final Map<String, List<Map<String, dynamic>>> loaded = {};

      data.forEach((applianceName, pointsData) {
        if (pointsData is! Map) return;

        final points = Map<String, dynamic>.from(pointsData);

        final list = points.values
            .map((p) {
              if (p is! Map) return null;

              final point = Map<String, dynamic>.from(p);

              final ts = point["t"];
              if (ts == null) return null;

              return {
                "time": DateTime.fromMillisecondsSinceEpoch(
                  ts is int ? ts : parseValue(ts).toInt(),
                ),
                "power": parseValue(point["p"]),
              };
            })
            .whereType<Map<String, dynamic>>()
            .toList();

        list.sort(
          (a, b) => (a["time"] as DateTime)
              .compareTo(b["time"] as DateTime),
        );

        if (list.isNotEmpty) {
          loaded[applianceName] = list;
        }
      });

      setState(() {
        _liveChartData
          ..clear()
          ..addAll(loaded);

        if (_liveChartData.isNotEmpty) {
          chartReady = true;
        }
      });

      _scrollToLiveEdge();
    });
  }

  // ============================================================
  // USER
  // ============================================================

  void fetchUserName() {
    if (user != null) {
      setState(() {
        userName =
            user!.displayName ?? "User";
      });
    }
  }

  void loadUserPreferences() async {
    final snapshot =
        await prefRef.get();

    if (!snapshot.exists) return;

    final data =
        Map<String, dynamic>.from(
            snapshot.value as Map);

    setState(() {
      threshold =
          parseValue(
              data['threshold'] ??
                  threshold);

      pricePerUnit =
          parseValue(
              data['pricePerUnit'] ??
                  pricePerUnit);
    });
  }

  // ============================================================
  // BILL
  // ============================================================

  double _calculateBill(double units) {
    double u = units;
    double bill;

    if (u <= 50) {
      bill = u * 3.95;
    } else if (u <= 100) {
      bill =
          50 * 3.95 +
          (u - 50) * 7.74;
    } else if (u <= 200) {
      bill =
          50 * 3.95 +
          50 * 7.74 +
          (u - 100) * 10.06;
    } else if (u <= 300) {
      bill =
          50 * 3.95 +
          50 * 7.74 +
          100 * 10.06 +
          (u - 200) * 12.15;
    } else if (u <= 400) {
      bill =
          50 * 3.95 +
          50 * 7.74 +
          100 * 10.06 +
          100 * 12.15 +
          (u - 300) * 17.59;
    } else if (u <= 500) {
      bill =
          50 * 3.95 +
          50 * 7.74 +
          100 * 10.06 +
          100 * 12.15 +
          100 * 17.59 +
          (u - 400) * 20.84;
    } else {
      bill =
          50 * 3.95 +
          50 * 7.74 +
          100 * 10.06 +
          100 * 12.15 +
          100 * 17.59 +
          100 * 20.84 +
          (u - 500) * 22.65;
    }

    return bill + 75 + (bill * 0.18);
  }

  double get estimatedBill =>
      _calculateBill(
          unitsAccumulator.totalUnitsThisMonth);

  double get thresholdProgress =>
      threshold > 0
          ? (unitsAccumulator.totalUnitsThisMonth /
                  threshold)
              .clamp(0.0, 1.0)
          : 0.0;

  Color get thresholdColor {
    if (thresholdProgress >= 1.0) {
      return Colors.red;
    }

    if (thresholdProgress >= 0.75) {
      return Colors.orange;
    }

    return Colors.greenAccent;
  }

  // ============================================================
  // NOTIFICATIONS
  // ============================================================

  Map<String, String>? get latestNotification {
    final real =
        notificationManager
            .dynamicNotifications;

    return real.isEmpty
        ? null
        : real.first;
  }

  int get notificationCount =>
      notificationManager
          .dynamicNotifications
          .length +
      NotificationScreen
          .staticNotifications
          .length;

  // ============================================================
  // ICONS
  // ============================================================

  IconData _iconFor(String key) {
    switch (key) {
      case "Fan":
        return Icons.air;

      case "Light":
        return Icons.lightbulb;

      case "AC":
        return Icons.ac_unit;

      case "Fridge":
        return Icons.kitchen;

      case "TV":
        return Icons.tv;

      case "Bulb":
        return Icons.lightbulb_outline;

      default:
        return Icons.device_unknown;
    }
  }

  Color _colorFor(String key) {
    switch (key) {
      case "Fan":
        return Colors.orange;

      case "Light":
        return Colors.yellow.shade700;

      case "AC":
        return Colors.blue;

      case "Fridge":
        return Colors.teal;

      case "TV":
        return Colors.purple;

      case "Bulb":
        return Colors.amber;

      default:
        return Colors.grey;
    }
  }

  // ============================================================
  // GRAPH HELPERS
  // ============================================================

  double _niceYMax(double dataMax) {
    if (dataMax <= 0) return 500.0;

    if (dataMax <= 100) return 100.0;

    if (dataMax <= 200) return 200.0;

    if (dataMax <= 500) return 500.0;

    if (dataMax <= 1000) return 1000.0;

    if (dataMax <= 1500) return 1500.0;

    if (dataMax <= 2000) return 2000.0;

    return ((dataMax / 500.0)
            .ceil() *
        500)
        .toDouble();
  }

  List<List<Map<String, dynamic>>>
      _splitIntoSegments(
    List<Map<String, dynamic>> points,
  ) {
    const gapThreshold =
        Duration(seconds: 15);

    final segments =
        <List<Map<String, dynamic>>>[];

    List<Map<String, dynamic>> current =
        [];

    for (final p in points) {
      if (current.isNotEmpty) {
        final prev =
            current.last["time"]
                as DateTime;

        final t =
            p["time"] as DateTime;

        if (t.difference(prev) >
            gapThreshold) {

          segments.add(current);

          current = [];
        }
      }

      current.add(p);
    }

    if (current.isNotEmpty) {
      segments.add(current);
    }

    return segments;
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final isDark =
        Theme.of(context).brightness ==
            Brightness.dark;

    final cardWidth =
        (MediaQuery.of(context)
                    .size
                    .width -
                30) /
            2;

    return AnimatedBuilder(
      animation: unitsAccumulator,
      builder: (context, _) => _buildScaffold(context, isDark, cardWidth),
    );
  }

  Widget _buildScaffold(
      BuildContext context, bool isDark, double cardWidth) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Dashboard",
          style:
              TextStyle(color: Colors.white),
        ),
        backgroundColor:
            const Color.fromARGB(
                255, 30, 58, 138),
        actions: [
          Padding(
            padding:
                const EdgeInsets.only(
                    right: 12),
            child:
                PopupMenuButton<int>(
              tooltip: "Notifications",
              offset:
                  const Offset(0, 50),
              shape:
                  RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(
                        15),
              ),
              color: isDark
                  ? Colors.grey[850]
                  : Colors.white,
              itemBuilder:
                  (context) =>
                      <PopupMenuEntry<int>>[
                if (latestNotification !=
                    null)
                  PopupMenuItem<int>(
                    enabled: true,
                    padding:
                        EdgeInsets.zero,
                    child: Container(
                      width:
                          double.infinity,
                      padding:
                          const EdgeInsets
                              .symmetric(
                        vertical: 8,
                        horizontal: 10,
                      ),
                      decoration:
                          BoxDecoration(
                        color: isDark
                            ? Colors.white
                                .withOpacity(
                                    0.08)
                            : Colors.blue
                                .withOpacity(
                                    0.08),
                        borderRadius:
                            BorderRadius
                                .circular(
                                    8),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons
                                .notifications_active,
                            size: 18,
                            color:
                                Colors.blue,
                          ),
                          const SizedBox(
                              width: 10),
                          Expanded(
                            child: Text(
                              latestNotification![
                                  "title"]!,
                              style:
                                  TextStyle(
                                fontSize:
                                    13,
                                fontWeight:
                                    FontWeight
                                        .w500,
                                color: isDark
                                    ? Colors
                                        .white
                                    : Colors
                                        .black87,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const PopupMenuDivider(),
                PopupMenuItem<int>(
                  child: TextButton(
                    onPressed: () =>
                        Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const NotificationScreen(),
                      ),
                    ),
                    child:
                        const Text(
                            "View All"),
                  ),
                ),
              ],
              child: Stack(
                clipBehavior:
                    Clip.none,
                children: [
                  const Icon(
                    Icons.notifications,
                    color:
                        Colors.white,
                  ),
                  if (notificationCount >
                      0)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        padding:
                            const EdgeInsets
                                .all(4),
                        decoration:
                            const BoxDecoration(
                          color: Colors.red,
                          shape:
                              BoxShape.circle,
                        ),
                        child: Text(
                          notificationCount
                              .toString(),
                          style:
                              const TextStyle(
                            fontSize: 10,
                            color:
                                Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),

      drawer:
          const AppDrawer(
              currentIndex: 0),

      body: Padding(
        padding:
            const EdgeInsets.all(10),
        child:
            SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(
                  height: 10),

              Align(
                alignment:
                    Alignment.centerLeft,
                child: Text(
                  "Welcome, $userName",
                  style:
                      TextStyle(
                    fontSize: 22,
                    fontWeight:
                        FontWeight.bold,
                    color: isDark
                        ? Colors.white
                        : Colors.black87,
                  ),
                ),
              ),

              const SizedBox(
                  height: 20),

              // =================================================
              // DASHBOARD CARDS
              // =================================================

              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [

                  // TODAY'S CONSUMPTION
                  _statCard(
                    "Today's Consumption",
                    "${unitsAccumulator.totalUnitsToday.toStringAsFixed(3)} kWh",
                    Icons.today,
                    Colors.deepPurple,
                    cardWidth,
                  ),

                  // VOLTAGE
                  _statCard(
                    "Voltage",
                    "${unitsAccumulator.totalVoltage.toStringAsFixed(1)} V",
                    Icons.bolt,
                    Colors.orange,
                    cardWidth,
                  ),

                  // CURRENT
                  _statCard(
                    "Total Current",
                    "${unitsAccumulator.totalCurrent.toStringAsFixed(2)} A",
                    Icons.flash_on,
                    Colors.green,
                    cardWidth,
                  ),

                  // POWER
                  _statCard(
                    "Total Power",
                    "${unitsAccumulator.totalPower.toStringAsFixed(1)} W",
                    Icons.power,
                    Colors.blue,
                    cardWidth,
                  ),
                ],
              ),

              const SizedBox(
                  height: 15),

              // =================================================
              // MONTHLY THRESHOLD
              // =================================================

              _thresholdProgressCard(),

              const SizedBox(
                  height: 20),

              // =================================================
              // GRAPH HEADER
              // =================================================

              Row(
                mainAxisAlignment:
                    MainAxisAlignment
                        .spaceBetween,
                children: [
                  Text(
                    "Live Power Usage",
                    style:
                        TextStyle(
                      fontSize: 18,
                      fontWeight:
                          FontWeight.bold,
                      color: isDark
                          ? Colors.white
                          : Colors.black87,
                    ),
                  ),
                  Text(
                    "Scroll to explore the full day ->",
                    style:
                        TextStyle(
                      fontSize: 11,
                      color: isDark
                          ? Colors.white38
                          : Colors.black38,
                    ),
                  ),
                ],
              ),

              const SizedBox(
                  height: 10),

              // =================================================
              // EXISTING GRAPH
              // =================================================

              _buildLiveChart(),

              const SizedBox(
                  height: 20),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // LIVE GRAPH
  // ============================================================

  Widget _buildLiveChart() {
    final applianceColors = {
      "AC": Colors.blue,
      "Fan": Colors.orange,
      "Light": Colors.yellow.shade700,
      "Fridge": Colors.teal,
      "TV": Colors.purple,
      "Bulb": Colors.amber,
    };

    final activeNames =
        _liveChartData.keys
            .where((k) =>
                _liveChartData[k]!
                    .isNotEmpty)
            .toList();

    if (!chartReady ||
        activeNames.isEmpty) {
      return Container(
        height: 300,
        decoration:
            BoxDecoration(
          color:
              const Color(0xFF2A2A2A),
          borderRadius:
              BorderRadius.circular(
                  12),
        ),
        child:
            const Center(
          child: Column(
            mainAxisAlignment:
                MainAxisAlignment
                    .center,
            children: [
              CircularProgressIndicator(
                color:
                    Colors.white38,
              ),
              SizedBox(
                  height: 12),
              Text(
                "Waiting for live data...\nTurn on an appliance to start.",
                textAlign:
                    TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color:
                      Colors.white38,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final now =
        DateTime.now();

    final earliest =
        DateTime(
      now.year,
      now.month,
      now.day,
    );

    final nowSeconds =
        now.difference(
                earliest)
            .inSeconds
            .toDouble();

    double dataMax = 0;

    for (final name
        in activeNames) {
      for (final p
          in _liveChartData[
              name]!) {
        final pw =
            p["power"] as double;

        if (pw > dataMax) {
          dataMax = pw;
        }
      }
    }

    final yMax =
        _niceYMax(dataMax);

    final yInterval =
        yMax / 4.0;

    final lineBars =
        <LineChartBarData>[];

    final barApplianceNames =
        <String>[];

    for (final name
        in activeNames) {
      final color =
          applianceColors[
                  name] ??
              Colors.grey;

      final segments =
          _splitIntoSegments(
              _liveChartData[
                  name]!);

      for (final seg
          in segments) {
        final spots =
            seg.map((p) {
          final t =
              p["time"]
                  as DateTime;

          final power =
              p["power"]
                  as double;

          final x =
              t.difference(
                      earliest)
                  .inSeconds
                  .toDouble();

          return FlSpot(
              x, power);
        }).toList();

        lineBars.add(
          LineChartBarData(
            spots: spots,
            isCurved: false,
            color: color,
            barWidth: 2,
            dotData:
                const FlDotData(
                    show: false),
            belowBarData:
                BarAreaData(
              show: true,
              color:
                  color.withOpacity(
                      0.07),
            ),
          ),
        );

        barApplianceNames
            .add(name);
      }
    }

    final chartWidth =
        _pxPerHour * 24;

    return Container(
      decoration:
          BoxDecoration(
        color:
            const Color(0xFF2A2A2A),
        borderRadius:
            BorderRadius.circular(
                12),
      ),
      padding:
          const EdgeInsets
              .fromLTRB(
        8,
        16,
        12,
        12,
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment
                .start,
        children: [

          Padding(
            padding:
                const EdgeInsets
                    .only(
              left: 8,
              bottom: 12,
            ),
            child: Row(
              crossAxisAlignment:
                  CrossAxisAlignment
                      .start,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children:
                        activeNames
                            .map(
                                (name) {
                      final color =
                          applianceColors[
                                  name] ??
                              Colors.grey;

                      final power =
                          unitsAccumulator.applianceBreakdown[
                                  name]?[
                              "power"] ??
                              0.0;

                      return Row(
                        mainAxisSize:
                            MainAxisSize
                                .min,
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration:
                                BoxDecoration(
                              color:
                                  color,
                              borderRadius:
                                  BorderRadius
                                      .circular(
                                          3),
                            ),
                          ),
                          const SizedBox(
                              width: 5),
                          Text(
                            "$name (${(power as double).toStringAsFixed(0)}W)",
                            style:
                                const TextStyle(
                              fontSize:
                                  11,
                              color: Colors
                                  .white70,
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),

                if (!_followLive)
                  GestureDetector(
                    onTap: () {
                      setState(() =>
                          _followLive =
                              true);

                      _scrollToLiveEdge(
                          force: true);
                    },
                    child:
                        Container(
                      padding:
                          const EdgeInsets
                              .symmetric(
                        horizontal:
                            10,
                        vertical: 5,
                      ),
                      decoration:
                          BoxDecoration(
                        color: Colors
                            .blue
                            .withOpacity(
                                0.2),
                        borderRadius:
                            BorderRadius
                                .circular(
                                    20),
                        border:
                            Border.all(
                          color: Colors
                              .blueAccent
                              .withOpacity(
                                  0.6),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize:
                            MainAxisSize
                                .min,
                        children: [
                          Icon(
                            Icons
                                .my_location,
                            size: 13,
                            color: Colors
                                .blueAccent,
                          ),
                          SizedBox(
                              width: 4),
                          Text(
                            "Now",
                            style:
                                TextStyle(
                              fontSize:
                                  11,
                              color: Colors
                                  .blueAccent,
                              fontWeight:
                                  FontWeight
                                      .w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),

          SizedBox(
            height: 340,
            child:
                SingleChildScrollView(
              controller:
                  _chartScrollController,
              scrollDirection:
                  Axis.horizontal,
              physics:
                  const ClampingScrollPhysics(),
              child: SizedBox(
                width: chartWidth,
                height: 340,
                child: LineChart(
                  LineChartData(
                    minX: 0,
                    maxX:
                        _fullDaySeconds,
                    minY: 0,
                    maxY: yMax,
                    backgroundColor:
                        const Color(
                            0xFF2A2A2A),
                    clipData:
                        const FlClipData(
                      top: false,
                      bottom: true,
                      left: true,
                      right: true,
                    ),
                    gridData:
                        FlGridData(
                      show: true,
                      horizontalInterval:
                          yInterval,
                      verticalInterval:
                          3600,
                      getDrawingHorizontalLine:
                          (_) =>
                              FlLine(
                        color: Colors
                            .white
                            .withOpacity(
                                0.1),
                        strokeWidth: 1,
                      ),
                      getDrawingVerticalLine:
                          (_) =>
                              FlLine(
                        color: Colors
                            .white
                            .withOpacity(
                                0.07),
                        strokeWidth: 1,
                      ),
                    ),
                    borderData:
                        FlBorderData(
                      show: true,
                      border:
                          Border(
                        bottom:
                            BorderSide(
                          color: Colors
                              .white
                              .withOpacity(
                                  0.2),
                          width: 1,
                        ),
                        left:
                            BorderSide(
                          color: Colors
                              .white
                              .withOpacity(
                                  0.2),
                          width: 1,
                        ),
                      ),
                    ),
                    extraLinesData:
                        ExtraLinesData(
                      verticalLines: [
                        VerticalLine(
                          x:
                              nowSeconds,
                          color: Colors
                              .white54,
                          strokeWidth:
                              1,
                          dashArray:
                              [4, 4],
                          label:
                              VerticalLineLabel(
                            show:
                                true,
                            alignment:
                                Alignment
                                    .topRight,
                            style:
                                const TextStyle(
                              fontSize:
                                  9,
                              color: Colors
                                  .white54,
                            ),
                            labelResolver:
                                (_) =>
                                    "now",
                          ),
                        ),
                      ],
                    ),
                    titlesData:
                        FlTitlesData(
                      topTitles:
                          const AxisTitles(
                        sideTitles:
                            SideTitles(
                                showTitles:
                                    false),
                      ),
                      rightTitles:
                          const AxisTitles(
                        sideTitles:
                            SideTitles(
                                showTitles:
                                    false),
                      ),
                      leftTitles:
                          AxisTitles(
                        axisNameWidget:
                            const Padding(
                          padding:
                              EdgeInsets
                                  .only(
                            bottom: 4,
                          ),
                          child:
                              Text(
                            "Power (W)",
                            style:
                                TextStyle(
                              fontSize:
                                  11,
                              color: Colors
                                  .white54,
                            ),
                          ),
                        ),
                        sideTitles:
                            SideTitles(
                          showTitles:
                              true,
                          interval:
                              yInterval,
                          reservedSize:
                              52,
                          getTitlesWidget:
                              (value, _) =>
                                  Text(
                            value.toStringAsFixed(
                                0),
                            style:
                                const TextStyle(
                              fontSize:
                                  10,
                              color: Colors
                                  .white60,
                            ),
                          ),
                        ),
                      ),
                      bottomTitles:
                          AxisTitles(
                        axisNameWidget:
                            const Padding(
                          padding:
                              EdgeInsets
                                  .only(
                            top: 6,
                          ),
                          child:
                              Text(
                            "Time of day",
                            style:
                                TextStyle(
                              fontSize:
                                  11,
                              color: Colors
                                  .white54,
                            ),
                          ),
                        ),
                        sideTitles:
                            SideTitles(
                          showTitles:
                              true,
                          interval:
                              3600,
                          getTitlesWidget:
                              (value, _) {
                            final t =
                                earliest.add(
                              Duration(
                                seconds:
                                    value.toInt(),
                              ),
                            );

                            final label =
                                "${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}";

                            return Padding(
                              padding:
                                  const EdgeInsets
                                      .only(
                                top: 4,
                              ),
                              child:
                                  Text(
                                label,
                                style:
                                    const TextStyle(
                                  fontSize:
                                      9,
                                  color: Colors
                                      .white60,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    lineTouchData:
                        LineTouchData(
                      enabled: true,
                      touchTooltipData:
                          LineTouchTooltipData(
                        getTooltipColor:
                            (_) =>
                                const Color(
                                    0xFF3A3A3A),
                        getTooltipItems:
                            (spots) =>
                                spots.map(
                          (spot) {
                            final name =
                                barApplianceNames
                                            .length >
                                        spot.barIndex
                                    ? barApplianceNames[
                                        spot.barIndex]
                                    : "";

                            return LineTooltipItem(
                              "$name\n${spot.y.toStringAsFixed(1)} W",
                              const TextStyle(
                                color:
                                    Colors.white,
                                fontSize:
                                    11,
                                fontWeight:
                                    FontWeight
                                        .w500,
                              ),
                            );
                          },
                        ).toList(),
                      ),
                    ),
                    lineBarsData:
                        lineBars,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // MONTHLY THRESHOLD CARD
  // ============================================================

  Widget _thresholdProgressCard() {
    final bool isExceeded =
        unitsAccumulator.totalUnitsThisMonth >=
            threshold;

    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets
              .symmetric(
        vertical: 16,
        horizontal: 18,
      ),
      decoration:
          BoxDecoration(
        color:
            const Color.fromARGB(
                255, 30, 58, 138),
        borderRadius:
            BorderRadius.circular(
                12),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment
                .start,
        children: [

          Row(
            children: [
              const Icon(
                Icons.track_changes,
                color: Colors.white,
                size: 26,
              ),
              const SizedBox(
                  width: 10),

              const Text(
                "Monthly Usage",
                style:
                    TextStyle(
                  fontSize: 16,
                  fontWeight:
                      FontWeight.bold,
                  color:
                      Colors.white70,
                ),
              ),

              const Spacer(),

              if (isExceeded)
                Container(
                  padding:
                      const EdgeInsets
                          .symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration:
                      BoxDecoration(
                    color:
                        Colors.white24,
                    borderRadius:
                        BorderRadius
                            .circular(
                                20),
                  ),
                  child:
                      const Text(
                    "Exceeded",
                    style:
                        TextStyle(
                      fontSize: 11,
                      color:
                          Colors.white,
                      fontWeight:
                          FontWeight
                              .bold,
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(
              height: 10),

          Row(
            mainAxisAlignment:
                MainAxisAlignment
                    .spaceBetween,
            children: [
              Expanded(
                child: Text(
                  "${unitsAccumulator.totalUnitsThisMonth.toStringAsFixed(2)} kWh this month",
                  style:
                      const TextStyle(
                    fontSize: 17,
                    fontWeight:
                        FontWeight
                            .bold,
                    color:
                        Colors.white,
                  ),
                ),
              ),

              Text(
                "Limit: ${threshold.toStringAsFixed(0)} kWh",
                style:
                    const TextStyle(
                  fontSize: 13,
                  color:
                      Colors.white70,
                ),
              ),
            ],
          ),

          const SizedBox(
              height: 10),

          ClipRRect(
            borderRadius:
                BorderRadius.circular(
                    8),
            child:
                LinearProgressIndicator(
              value:
                  thresholdProgress,
              minHeight: 14,
              backgroundColor:
                  Colors.white24,
              valueColor:
                  AlwaysStoppedAnimation<
                      Color>(
                thresholdColor,
              ),
            ),
          ),

          const SizedBox(
              height: 6),

          Row(
            mainAxisAlignment:
                MainAxisAlignment
                    .spaceBetween,
            children: [
              Expanded(
                child: Text(
                  isExceeded
                      ? "Limit exceeded! Reduce usage."
                      : thresholdProgress >=
                              0.75
                          ? "Approaching limit, be careful."
                          : "Within budget.",
                  style:
                      TextStyle(
                    fontSize: 12,
                    color:
                        thresholdColor,
                    fontWeight:
                        FontWeight
                            .w500,
                  ),
                ),
              ),

              Text(
                "${(thresholdProgress * 100).toStringAsFixed(1)}%",
                style:
                    const TextStyle(
                  fontSize: 11,
                  color:
                      Colors.white70,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ============================================================
  // STAT CARD
  // ============================================================

  Widget _statCard(
    String title,
    String value,
    IconData icon,
    Color color,
    double width,
  ) {
    return Container(
      width: width,
      padding:
          const EdgeInsets
              .symmetric(
        vertical: 20,
        horizontal: 15,
      ),
      decoration:
          BoxDecoration(
        color: color,
        borderRadius:
            BorderRadius.circular(
                12),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color:
                Colors.white,
            size: 30,
          ),

          const SizedBox(
              width: 15),

          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment
                      .start,
              children: [
                Text(
                  title,
                  style:
                      const TextStyle(
                    fontSize: 14,
                    fontWeight:
                        FontWeight
                            .bold,
                    color:
                        Colors.white70,
                  ),
                ),

                const SizedBox(
                    height: 5),

                Text(
                  value,
                  style:
                      const TextStyle(
                    fontSize: 18,
                    fontWeight:
                        FontWeight
                            .bold,
                    color:
                        Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
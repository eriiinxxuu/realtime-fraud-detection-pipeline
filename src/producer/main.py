from collections import defaultdict, deque
from datetime import datetime, timedelta, timezone
import os
import random
import signal
import time
from typing import Optional
from zoneinfo import ZoneInfo
import geonamescache
from timezonefinder import TimezoneFinder
from confluent_kafka import Producer, Consumer, KafkaError, KafkaException
from dotenv import load_dotenv
from faker import Faker
from geopy.distance import geodesic
from jsonschema import ValidationError, validate, FormatChecker
import json
import logging
logging.basicConfig(
    format='%(asctime)s - %(levelname)s - %(module)s - %(message)s',
    level=logging.INFO
)

logger = logging.getLogger(__name__)
load_dotenv(dotenv_path="/app/.env")

fake = Faker()



TRANSACTION_SCHEMA = {
    "type": "object",
    "required": [
        "transaction_id", "user_id", "amount", "currency", "timestamp",
        "merchant", "location", "device_id", "mcc", "is_fraud",
        "risk_signals", "risk_score", "user_profile_summary"
    ],
    "properties": {
        # basics attributes
        "transaction_id": {"type": "string"},
        "user_id": {"type": "integer"},
        "amount": {"type": "number"},
        "currency": {"type": "string"},
        "timestamp": {"type": "string"},  # ISO format
        "merchant": {"type": "string"},
        "location": {"type": "string"},
        "device_id": {"type": "string"},
        "mcc": {"type": "string"},
        
        # fraud related
        "is_fraud": {"type": "integer", "enum": [0, 1]},
        "fraud_type": {"type": ["string", "null"]},
        "fraud_details": {
            "type": ["object", "null"],
            "properties": {
                "fraud_subtype": {"type": "string"},
                "original_device": {"type": "string"},
                "compromised_via": {"type": "string"},
                "test_count": {"type": "integer"},
                "pattern": {"type": "string"},
                "merchant_risk_level": {"type": "string"},
                "mcc_category": {"type": "string"},
                "travel_speed_required": {"type": "string"},
                "legitimate_vpn_possible": {"type": "boolean"},
                "local_hour": {"type": "integer"},
                "user_night_rate": {"type": "number"},
                "transactions_last_hour": {"type": "integer"},
                "threshold_exceeded": {"type": "boolean"},
                "is_recurring_merchant": {"type": "boolean"},
                "previous_chargebacks": {"type": "integer"},
                "delivery_confirmed": {"type": "boolean"},
                "dispute_reason": {"type": "string"}
            }
        },
        
        
        "risk_signals": {
            "type": "array",
            "items": {"type": "string"}
        },
        "risk_score": {"type": "number", "minimum": 0, "maximum": 1},
        "user_profile_summary": {
            "type": "object",
            "required": ["account_age_days", "is_frequent_traveler", "avg_transaction", "home_country"],
            "properties": {
                "account_age_days": {"type": "integer"},
                "is_frequent_traveler": {"type": "boolean"},
                "avg_transaction": {"type": "number"},
                "home_country": {"type": "string"}
            }
        }
    },
    
    # fraud validation
    "if": {
        "properties": {"is_fraud": {"const": 1}}
    },
    "then": {
        "required": ["fraud_type", "fraud_details"],
        "properties": {
            "fraud_type": {"type": "string"},
            "fraud_details": {"type": "object"}
        }
    },
    "else": {
        "properties": {
            "fraud_type": {"const": None},
            "fraud_details": {"const": None}
        }
    }
}


class TransactionProducer:
    def __init__(self):
        # Initialization code for the producer
        self.bootstrap_servers = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
        self.kafka_username = os.getenv("KAFKA_USERNAME")
        self.kafka_password = os.getenv("KAFKA_PASSWORD")
        self.topic = os.getenv("KAFKA_TOPIC", "transactions")
        self.running = False

        # configure Confluent Kafka producer
        self.producer_config = {
            'bootstrap.servers': self.bootstrap_servers,
            'security.protocol': 'SASL_SSL' if self.kafka_username and self.kafka_password else 'PLAINTEXT',
            # 'sasl.mechanism': 'PLAIN' if self.kafka_username and self.kafka_password else None,
            # 'sasl.username': self.kafka_username,
            # 'sasl.password': self.kafka_password,
            'client.id': 'transaction-producer',
            'compression.type': 'gzip',
            'linger.ms': 5,
            'batch.size': 15000,
        }

        if self.kafka_username and self.kafka_password:
            self.producer_config['sasl.mechanism'] = 'PLAIN'
            self.producer_config['sasl.username'] = self.kafka_username
            self.producer_config['sasl.password'] = self.kafka_password

        try:
            self.producer = Producer(self.producer_config)
            logger.info("Kafka Producer initialized successfully.")
        except KafkaException as e:
            logger.error(f"Failed to initialize Kafka Producer: {e}")
            raise e
        
        # Target fraud rate control
        self.target_fraud_rate = 0.02  # 2% target fraud rate
        self.fraud_count = 0
        self.total_count = 0

        self.compromised_users = set(random.sample(range(1000, 10000), k=50)) # ~5% of users compromised
        self.high_risk_merchants = ['QuickCash','GlobalDigital','FastLoans','MoneyNow','CashExpress','CryptoExchangePro']

        # Initialize geonames cache
        self.gc = geonamescache.GeonamesCache()

        # Initialize TimezoneFinder
        self.tf = TimezoneFinder()

        # Cache for coordinates and timezones (lazy loaded)
        self.capital_coords_cache = {}
        self.country_timezones_cache = {}

        # Get all available country codes
        self.available_countries = list(self.gc.get_countries().keys())

        # User profiles
        self.user_profiles = self._initialize_user_profiles()

        # User transaction history (for velocity checks and geo-anomaly detection)
        self.user_transaction_history = defaultdict(lambda: deque(maxlen=100))

        # User chargeback history (for friendly fraud detection)
        self.user_chargeback_history = defaultdict(list)

        # Merchant Category Codes (MCC)
        self.high_risk_mcc = ['6211', '5962', '7995', '7801']  # Crypto, gift cards, gambling, etc.


        # Setup signal handlers for graceful shutdown
        signal.signal(signal.SIGINT, self.shutdown)
        signal.signal(signal.SIGTERM, self.shutdown)

    
    def shutdown(self, signum=None, frame=None):
        if self.running:
            logger.info("Shutting down producer...")
            self.running = False
            if self.producer:
                self.producer.flush()
                self.producer.close()
            logger.info("Producer closed.")

    def _get_capital_coordinates(self, country_code: str) -> Optional[tuple]:
        """Lazy load capital coordinates for a country"""
        if country_code in self.capital_coords_cache:
            return self.capital_coords_cache[country_code]
        
        try:
            countries = self.gc.get_countries()
            country_data = countries.get(country_code)
            
            if not country_data:
                return None
            
            capital = country_data.get('capital')
            if not capital:
                return None
            
            cities = self.gc.get_cities()
            for city_id, city_data in cities.items():
                if (city_data['name'] == capital and 
                    city_data['countrycode'] == country_code):
                    
                    coords = (city_data['latitude'], city_data['longitude'])
                    self.capital_coords_cache[country_code] = coords
                    return coords
            
            return None
            
        except Exception:
            return None
    

    def _get_country_timezone(self, country_code: str) -> str:
        """
        Lazy load timezone for a country
        Returns IANA timezone name or 'UTC' as fallback
        """
        # Check cache first
        if country_code in self.country_timezones_cache:
            return self.country_timezones_cache[country_code]
        
        try:
            # Get coordinates first
            coords = self._get_capital_coordinates(country_code)
            if not coords:
                self.country_timezones_cache[country_code] = 'UTC'
                return 'UTC'
            
            # Get timezone from coordinates
            lat, lon = coords
            tz_name = self.tf.timezone_at(lat=lat, lng=lon)
            
            if tz_name:
                self.country_timezones_cache[country_code] = tz_name
                return tz_name
            else:
                self.country_timezones_cache[country_code] = 'UTC'
                return 'UTC'
                
        except Exception as e:
            logger.error(f"Error getting timezone for {country_code}: {e}")
            self.country_timezones_cache[country_code] = 'UTC'
            return 'UTC'

    def _initialize_user_profiles(self) -> dict[int, dict]:
        """Create baseline behavior patterns for each user"""
        profiles = {}
        for user_id in range(1000, 10000):
            home_country = random.choice(self.available_countries)
            avg_amount = random.uniform(30, 300)
            
            profiles[user_id] = {
                'home_country': home_country,
                'timezone': self._get_country_timezone(home_country),
                'avg_transaction': avg_amount,
                'typical_merchants': [fake.company() for _ in range(5)],
                'night_transaction_rate': random.uniform(0.01, 0.15),  # Historical night transaction rate
                'device_id': f"dev_{user_id}_{random.randint(100, 999)}",
                'created_date': datetime.now(timezone.utc) - timedelta(days=random.randint(30, 730)),
                'is_frequent_traveler': random.random() < 0.08,  # 8% are business travelers,
                'uses_vpn_regularly': random.random() < 0.05,    # 5% use VPN regularly
                'has_secondary_residence': random.random() < 0.03,  # 3% have secondary residence
                'secondary_country': None,
                'chargeback_tendency': random.random() < 0.02,  # 2% have chargeback tendency
            }

            # Set secondary residence country
            if profiles[user_id]['has_secondary_residence']:
                profiles[user_id]['secondary_country'] = random.choice(
                    [c for c in self.available_countries if c != home_country]
                )
        return profiles
    
    
    def _get_user_local_time(self, user_id: int, current_utc: datetime) -> datetime:
        """Get user's local time using zoneinfo"""
        profile = self.user_profiles[user_id]
        tz_name = profile['timezone']
        
        try:
            tz = ZoneInfo(tz_name)
            return current_utc.astimezone(tz)
        except Exception:
            return current_utc
        
    
    def _get_user_local_hour(self, user_id: int, current_utc: datetime) -> int:
        """Get current hour in user's timezone"""
        return self._get_user_local_time(user_id, current_utc).hour
    
 
    def _calculate_distance(self, country1: str, country2: str) -> float:
        """
        Calculate distance between two countries using geopy
        Lazy loads coordinates as needed
        """
        # Get coordinates (lazy loaded)
        coords1 = self._get_capital_coordinates(country1)
        coords2 = self._get_capital_coordinates(country2)
        
        if not coords1 or not coords2:
            return 0
        
        # Calculate distance
        distance = geodesic(coords1, coords2).kilometers
        return distance
    

    def _check_impossible_travel(self, user_id: int, current_location: str, 
                                 current_time: datetime) -> bool:
        """Check if impossible travel exists"""
        history = self.user_transaction_history[user_id]
        
        if not history:
            return False
        
        last_txn = history[-1]
        last_location = last_txn['location']
        last_time = last_txn['timestamp']
        
        if last_location == current_location:
            return False
        
        time_diff = (current_time - last_time).total_seconds() / 3600
        distance = self._calculate_distance(last_location, current_location)
        
        # 900 km/h assumed max speed for air travel
        max_speed = 900
        min_required_hours = distance / max_speed
        
        return time_diff < min_required_hours and distance > 500
    

    def _count_recent_transactions(self, user_id: int, minutes: int) -> int:
        """Count number of transactions in last N minutes"""
        history = self.user_transaction_history[user_id]
        if not history:
            return 0
        
        cutoff_time = datetime.now(timezone.utc) - timedelta(minutes=minutes)
        count = sum(1 for txn in history if txn['timestamp'] > cutoff_time)
        return count
    

    def _is_legitimate_anomaly(self, user_id: int, transaction: dict, 
                               current_time: datetime) -> bool:
        """Determine if this is a legitimate anomaly behavior"""
        profile = self.user_profiles[user_id]
        
        # Business traveler's cross-border transaction
        if (profile['is_frequent_traveler'] and 
            transaction['location'] != profile['home_country']):
            return True
        
        # Transaction at secondary residence
        if (profile['has_secondary_residence'] and 
            transaction['location'] == profile['secondary_country']):
            return True
        
        # Geographic anomaly from VPN user
        if profile['uses_vpn_regularly']:
            return True
        
        return False
    

    def _check_friendly_fraud(self, user_id: int, transaction: dict) -> bool:
        """
        Detect friendly fraud - malicious chargeback after legitimate purchase
        Returns: (is_fraud, fraud_details)
        """
        profile = self.user_profiles[user_id]
        
        # Only users with chargeback tendency may commit friendly fraud
        if not profile['chargeback_tendency']:
            return False, None
        
        # Check historical chargeback count
        chargeback_count = len(self.user_chargeback_history[user_id])
        
        # Probability: Base 15% + 5% per historical chargeback, max 40%
        fraud_probability = min(0.15 + chargeback_count * 0.05, 0.4)
        
        if random.random() < fraud_probability:
            # Friendly fraud characteristics: usually high-value items, digital goods, or services
            if transaction['amount'] > profile['avg_transaction'] * 2:
                fraud_details = {
                    'fraud_subtype': 'friendly_fraud',
                    'is_recurring_merchant': random.random() < 0.3,
                    'previous_chargebacks': chargeback_count,
                    'delivery_confirmed': random.random() < 0.8,  # 80% confirmed delivery
                    'dispute_reason': random.choice([
                        'item_not_received', 
                        'item_not_as_described', 
                        'unauthorized_transaction',
                        'subscription_not_cancelled'
                    ])
                }
                
                # Record this chargeback
                self.user_chargeback_history[user_id].append({
                    'timestamp': datetime.now(timezone.utc),
                    'amount': transaction['amount']
                })
                
                return True, fraud_details
        
        return False, None
    
    def _calculate_risk_signals(self, txn: dict, user_id: int, 
                                current_time: datetime) -> list[str]:
        """Generate list of risk signals"""
        signals = []
        profile = self.user_profiles[user_id]
        
        # Amount anomaly
        if txn['amount'] > profile['avg_transaction'] * 5:
            signals.append('amount_anomaly_5x')
        elif txn['amount'] > profile['avg_transaction'] * 3:
            signals.append('amount_anomaly_3x')
        
        # Geographic anomaly
        if txn['location'] != profile['home_country']:
            if not (profile['has_secondary_residence'] and 
                    txn['location'] == profile['secondary_country']):
                signals.append('geo_anomaly')
        
        # High-risk merchant
        if txn['merchant'] in self.high_risk_merchants:
            signals.append('high_risk_merchant')
        
        # Velocity anomaly
        recent_10min = self._count_recent_transactions(user_id, 10)
        recent_1h = self._count_recent_transactions(user_id, 60)
        
        if recent_10min > 5:
            signals.append('velocity_10min_high')
        if recent_1h > 15:
            signals.append('velocity_1h_high')
        
        # Device change
        if txn['device_id'] != profile['device_id']:
            signals.append('device_change')
        
        # Night transaction
        user_local_hour = self._get_user_local_hour(user_id, current_time)
        if 2 <= user_local_hour <= 5:
            signals.append('night_transaction')
        
        # New account
        account_age = (current_time - profile['created_date']).days
        if account_age < 30:
            signals.append('new_account')
        
        # High-risk MCC
        if txn['mcc'] in self.high_risk_mcc:
            signals.append('high_risk_mcc')
        
        return signals
    
    def _calculate_risk_score(self, signals: list[str]) -> float:
        """Calculate composite risk score 0-1"""
        weights = {
            'amount_anomaly_3x': 0.10,
            'amount_anomaly_5x': 0.18,
            'geo_anomaly': 0.15,
            'high_risk_merchant': 0.20,
            'velocity_10min_high': 0.15,
            'velocity_1h_high': 0.12,
            'device_change': 0.20,
            'night_transaction': 0.08,
            'new_account': 0.10,
            'high_risk_mcc': 0.15,
        }
        
        score = sum(weights.get(signal, 0.05) for signal in signals)
        # add noise
        score += random.uniform(-0.05, 0.05)
        
        return round(max(0, min(score, 1.0)), 3)


    def generate_transaction(self) -> Optional[dict[str, any]]:
        """Generate a transaction, which may be normal or fraudulent"""

        self.total_count += 1
        user_id = random.randint(1000, 9999)
        profile = self.user_profiles[user_id]
        
        transaction = {
            'transaction_id': fake.uuid4(),
            'user_id': user_id,
            'amount': max(0.01, round(random.gauss(profile['avg_transaction'], 
                                                   profile['avg_transaction'] * 0.5), 2)),
            'currency': 'USD',
            'timestamp': (datetime.now(timezone.utc) + 
                          timedelta(seconds=random.randint(-300, 3000))),
            'merchant': random.choice(profile['typical_merchants']),
            'location': profile['home_country'],
            'device_id': profile['device_id'],
            'mcc': random.choice(['5411', '5812', '5999', '4814']), # Common MCCs
            'is_fraud': 0,
            'fraud_type': None,
            'fraud_details': None
        }

        is_fraud = 0
        fraud_type = None
        fraud_details = None
        user_id = transaction['user_id']
        current_time = transaction['timestamp']

    # ===================== Fraud Detection ======================



        # First check if this is a legitimate anomaly scenario
        is_legit_anomaly = self._is_legitimate_anomaly(user_id, transaction, current_time)

        # 1. Account Takeover (probability: ~35%)
        if user_id in self.compromised_users and not is_fraud:
            if random.random() < 0.35:  
                is_fraud = 1
                fraud_type = 'account_takeover'
                transaction['amount'] = round(random.uniform(800, 5000), 2)
                transaction['device_id'] = f"dev_fraud_{random.randint(10000, 99999)}"

                
                if random.random() < 0.6:
                    foreign_countries = [c for c in self.available_countries 
                                       if c != profile['home_country']]
                    if foreign_countries:
                        transaction['location'] = random.choice(foreign_countries)
                
                if random.random() < 0.5:
                    transaction['merchant'] = random.choice(self.high_risk_merchants)
                    transaction['mcc'] = random.choice(self.high_risk_mcc)

                fraud_details = {
                    'fraud_subtype': 'account_takeover',
                    'original_device': profile['device_id'],
                    'compromised_via': random.choice(['phishing', 'credential_stuffing', 'malware', 'social_engineering'])
                }

        # 2. Card Testing (probability: ~0.5%)
        if not is_fraud:
            recent_count = self._count_recent_transactions(user_id, minutes=10)

            if recent_count >= 5 and random.random() < 0.4: 
                is_fraud = 1
                fraud_type = 'card_testing'
                transaction['amount'] = round(random.uniform(0.50, 2.00), 2)
                fraud_details = {
                    'fraud_subtype': 'card_testing',
                    'test_count': recent_count,
                    'pattern': 'rapid_small_amounts'
                }
            elif transaction['amount'] < 5 and random.random() < 0.005: 
                is_fraud = 1
                fraud_type = 'card_testing'
                transaction['amount'] = round(random.uniform(0.01, 1.99), 2)
                transaction['merchant'] = 'Charity Donation Portal'
                fraud_details = {
                    'fraud_subtype': 'card_testing',
                    'test_count': 1,
                    'pattern': 'charity_test'
                }
          

        # 3. High-Risk Merchant Fraud (probability: ~0.3%)
        if not is_fraud and random.random() < 0.04:
            transaction['merchant'] = random.choice(self.high_risk_merchants)
            transaction['mcc'] = random.choice(self.high_risk_mcc)

            if random.random() < 0.08:  
                is_fraud = 1
                fraud_type = 'high_risk_merchant'
                transaction['amount'] = round(random.uniform(500, 3000), 2)
                fraud_details = {
                    'fraud_subtype': 'high_risk_merchant',
                    'merchant_risk_level': 'high',
                    'mcc_category': transaction['mcc']
                }

        # 4. Impossible Travel (probability: ~60%)
        if not is_fraud and not is_legit_anomaly:
            if self._check_impossible_travel(user_id, transaction['location'], current_time):
                if random.random() < 0.6: 
                    is_fraud = 1
                    fraud_type = 'impossible_travel'
                    transaction['device_id'] = f"dev_fraud_{random.randint(10000, 99999)}"
                    fraud_details = {
                        'fraud_subtype': 'impossible_travel',
                        'travel_speed_required': 'supersonic',
                        'legitimate_vpn_possible': False
                    }

        # 5. Unusual Hours Transaction (probability: ~0.25%)
        if not is_fraud and not is_legit_anomaly:
            user_local_hour = self._get_user_local_hour(user_id, current_time)
            
            if 2 <= user_local_hour <= 5:
                if (transaction['amount'] > profile['avg_transaction'] * 2 and 
                    profile['night_transaction_rate'] < 0.1):
                    if random.random() < 0.15:  
                        is_fraud = 1
                        fraud_type = 'unusual_hours'
                        transaction['amount'] = round(random.uniform(1000, 4000), 2)
                        
                        if random.random() < 0.4:
                            transaction['device_id'] = f"dev_fraud_{random.randint(10000, 99999)}"
                        
                        fraud_details = {
                            'fraud_subtype': 'unusual_hours',
                            'local_hour': user_local_hour,
                            'user_night_rate': profile['night_transaction_rate']
                        }
        # 6. Velocity Abuse (probability: ~30%)
        if not is_fraud:
            recent_1h = self._count_recent_transactions(user_id, minutes=60)
            
            if recent_1h >= 10 and random.random() < 0.3:  
                is_fraud = 1
                fraud_type = 'velocity_abuse'
                transaction['amount'] = round(random.uniform(50, 500), 2)
                fraud_details = {
                    'fraud_subtype': 'velocity_abuse',
                    'transactions_last_hour': recent_1h,
                    'threshold_exceeded': True
                }

        # 7. Friendly Fraud
        if not is_fraud:
            is_friendly_fraud, friendly_details = self._check_friendly_fraud(user_id, transaction)
            if is_friendly_fraud:
                is_fraud = 1
                fraud_type = 'friendly_fraud'
                fraud_details = friendly_details



        # ========== Add noise to make fraud detection more realistic ==========
        
        # 30% of fraud transactions appear more "normal"
        if is_fraud and random.random() < 0.5:
            transaction['amount'] = round(random.gauss(profile['avg_transaction'], 
                                                       profile['avg_transaction'] * 0.3), 2)
            transaction['device_id'] = profile['device_id']  # Keep original device
            transaction['location'] = profile['home_country']  # Keep home location
        
        # 10% of legitimate transactions have high-risk features (create false positives)
        if not is_fraud and random.random() < 0.15:
            transaction['amount'] = round(random.uniform(500, 2000), 2)
            if random.random() < 0.4:
                transaction['merchant'] = random.choice(self.high_risk_merchants)
            if random.random() < 0.3:
                transaction['device_id'] = f"dev_new_{random.randint(10000, 99999)}"

        # ========================== Output ==========================
        
        transaction['is_fraud'] = is_fraud
        transaction['fraud_type'] = fraud_type
        transaction['fraud_details'] = fraud_details

        # Calculate risk signals
        risk_signals = self._calculate_risk_signals(transaction, user_id, current_time)
        transaction['risk_signals'] = risk_signals

         # Calculate risk score
        transaction['risk_score'] = self._calculate_risk_score(risk_signals)

        # Add user profile summary
        transaction['user_profile_summary'] = {
            'account_age_days': (current_time - profile['created_date']).days,
            'is_frequent_traveler': profile['is_frequent_traveler'],
            'avg_transaction': round(profile['avg_transaction'], 2),
            'home_country': profile['home_country']
        }

        if is_fraud:
            self.fraud_count += 1


         # Record transaction history
        transaction_record = transaction.copy()
        transaction_record['timestamp'] = current_time
        self.user_transaction_history[user_id].append(transaction_record)
        # Convert timestamp to ISO format
        transaction['timestamp'] = current_time.isoformat()


        # validate transaction format
        if self.validate_transaction_schema(transaction):
            return transaction

    # def get_statistics(self) -> dict:
    #     """Get generator statistics"""
    #     return {
    #         'total_transactions': self.total_count,
    #         'fraud_transactions': self.fraud_count,
    #         'actual_fraud_rate': round(self.fraud_count / max(self.total_count, 1) * 100, 3),
    #         'target_fraud_rate': self.target_fraud_rate * 100,
    #         'compromised_users_count': len(self.compromised_users),
    #         'cached_coordinates': len(self.capital_coords_cache),
    #         'cached_timezones': len(self.country_timezones_cache)
    #     }

    def delivery_report(self, err, msg):
        # Callback for message delivery reports
        if err is not None:
            logger.error(f"Message delivery failed: {err}")
        else:
            logger.info(f"Message delivered to {msg.topic()} [{msg.partition()}] at offset {msg.offset()}")

    def validate_transaction_schema(self, transaction: dict[str, any]) -> bool:
        try:
            validate(
                instance = transaction,
                schema = TRANSACTION_SCHEMA,
                format_checker = FormatChecker()
            )
            return True
        except ValidationError as e:
            logger.error(f"Invalid transanction: {e.message}")
            return False


    def send_transaction(self) -> bool:
        # generate and send a single transaction message
        try:
            transaction = self.generate_transaction()

            self.producer.produce(
                self.topic, 
                key=transaction['transaction_id'], 
                value=json.dumps(transaction),
                callback=self.delivery_report
            )
            # produce() -> buffer -> Kafka - poll
            # trigger delivery report callbacks
            self.producer.poll(0)
            return True
        
        except KafkaException as e:
            logger.error(f"Failed to send message: {e}")
            return False


    def run_continuous_production(self, interval: float = 0.0):
        # run continuous message production with graceful shutdown
        self.running = True
        logger.info(f"Starting producer for topic: {self.topic}" )
        try:
            while self.running:
                if self.send_transaction():
                    time.sleep(interval)
        finally:
            self.shutdown()



if __name__ == "__main__":
    Producer = TransactionProducer()
    Producer.run_continuous_production()